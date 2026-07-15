# frozen_string_literal: true

require "rack/test"

RSpec.describe SpaceInferenceGateway::Metrics do
  include Rack::Test::Methods

  before { described_class.reset_all }

  let(:oai_ns_response) { fixture("oai_ns.json") }
  let(:oai_s_response)  { fixture("oai_s.txt") }
  let(:ant_ns_response) { fixture("ant_ns.json") }

  let(:upstream_fn) do
    lambda do |path, _body|
      case path
      when "/v1/chat/completions" then [oai_ns_response, 200, {}]
      when "/v1/messages"         then [ant_ns_response, 200, {}]
      else ["not found", 404, {}]
      end
    end
  end

  let(:app) { SpaceInferenceGateway::App.new(upstream_fn: upstream_fn) }

  # ── Registry completeness ────────────────────────────────────────────────────

  describe "registry" do
    it "defines all expected metrics" do
      names = described_class::REGISTRY.metrics.map(&:name)
      expect(names).to include(
        :sig_requests_total,
        :sig_request_duration_seconds,
        :sig_child_up,
        :sig_child_pid,
        :sig_child_rss_bytes,
        :sig_child_starts_total,
        :sig_model_operation_results_total,
        :sig_active_generations,
        :sig_active_model_info,
        :sig_upstream_errors_total,
        :sig_keepalive_comments_total,
      )
    end
  end

  # ── GET /metrics — format (AC1) ──────────────────────────────────────────────

  describe "GET /metrics" do
    before { get "/metrics" }

    it "returns HTTP 200" do
      expect(last_response.status).to eq(200)
    end

    it "content-type is Prometheus text/plain version=0.0.4" do
      expect(last_response.headers["content-type"]).to include("text/plain")
      expect(last_response.headers["content-type"]).to include("version=0.0.4")
    end

    it "body contains # HELP and # TYPE lines for sig_requests_total" do
      expect(last_response.body).to include("# HELP sig_requests_total")
      expect(last_response.body).to include("# TYPE sig_requests_total counter")
    end

    it "body contains # HELP and # TYPE lines for sig_keepalive_comments_total" do
      expect(last_response.body).to include("# HELP sig_keepalive_comments_total")
      expect(last_response.body).to include("# TYPE sig_keepalive_comments_total counter")
    end

    it "body contains # HELP and # TYPE lines for sig_child_up" do
      expect(last_response.body).to include("# HELP sig_child_up")
      expect(last_response.body).to include("# TYPE sig_child_up gauge")
    end
  end

  # ── Request counter (AC2) ────────────────────────────────────────────────────

  describe "request counter" do
    it "increments sig_requests_total for OAI non-stream" do
      body = JSON.generate({ model: "any", messages: [] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(described_class::REQUESTS.get(labels: { flavor: "oai", stream: "false" })).to eq(1)
    end

    it "increments sig_requests_total for OAI stream (legacy-seam path)" do
      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = SpaceInferenceGateway::App.new(upstream_fn: streaming_fn)
      session = Rack::MockSession.new(streaming_app)
      rack_env = Rack::Test::Session.new(session)

      body = JSON.generate({ model: "any", messages: [], stream: true })
      rack_env.post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(described_class::REQUESTS.get(labels: { flavor: "oai", stream: "true" })).to eq(1)
    end

    it "increments sig_requests_total for ANT non-stream" do
      body = JSON.generate({ model: "any", messages: [], max_tokens: 100 })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      expect(described_class::REQUESTS.get(labels: { flavor: "ant", stream: "false" })).to eq(1)
    end

    it "counter does not increment for non-inference routes" do
      get "/v1/models"
      expect(described_class::REQUESTS.get(labels: { flavor: "oai", stream: "false" })).to eq(0)
    end
  end

  # ── Upstream error counter (AC5) ─────────────────────────────────────────────

  describe "upstream error counter" do
    it "increments sig_upstream_errors_total via Oai relay" do
      relay = SpaceInferenceGateway::ErrorRelay::Oai.new
      relay.relay(400, '{"error":{"message":"bad"}}', flavor: :oai)
      expect(described_class::UPSTREAM_ERRORS.get(labels: { status: "400", flavor: "oai" })).to eq(1)
    end

    it "increments sig_upstream_errors_total via Oai relay for ANT flavor" do
      relay = SpaceInferenceGateway::ErrorRelay::Oai.new
      relay.relay(503, '{"error":{"message":"overloaded"}}', flavor: :ant)
      expect(described_class::UPSTREAM_ERRORS.get(labels: { status: "503", flavor: "ant" })).to eq(1)
    end

    it "increments sig_upstream_errors_total via Mlx relay for mlx string errors" do
      relay = SpaceInferenceGateway::ErrorRelay::Mlx.new
      relay.relay(400, '{"error":"bad json body"}', flavor: :oai)
      expect(described_class::UPSTREAM_ERRORS.get(labels: { status: "400", flavor: "oai" })).to eq(1)
    end

    it "increments via App when upstream returns an error" do
      err_fn = ->(_path, _body) { ['{"error":{"message":"upstream error","type":"api_error"}}', 502, {}] }
      err_app = SpaceInferenceGateway::App.new(upstream_fn: err_fn)
      session = Rack::MockSession.new(err_app)
      rack_env = Rack::Test::Session.new(session)
      body = JSON.generate({ model: "any", messages: [] })
      rack_env.post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(described_class::UPSTREAM_ERRORS.get(labels: { status: "502", flavor: "oai" })).to eq(1)
    end
  end

  # ── Active generations gauge (AC4) ───────────────────────────────────────────

  describe "active generations gauge" do
    it "starts at 0" do
      expect(described_class::ACTIVE_GENERATIONS.get).to eq(0)
    end

    it "increments and decrements via ModelController begin/end_generation" do
      registry   = SpaceInferenceGateway::ModelRegistry.load
      supervisor = double("supervisor", active_alias: nil, running?: false, pid: nil)
      controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)

      controller.begin_generation
      expect(described_class::ACTIVE_GENERATIONS.get).to eq(1)
      controller.end_generation
      expect(described_class::ACTIVE_GENERATIONS.get).to eq(0)
    end
  end

  # ── Model operation counter (AC4) ────────────────────────────────────────────

  describe "model operation results counter" do
    it "increments on unload" do
      registry   = SpaceInferenceGateway::ModelRegistry.load
      supervisor = double("supervisor", active_alias: nil, running?: false, pid: nil, stop: nil)
      controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)

      controller.unload
      expect(described_class::SWAP_RESULTS.get(labels: { operation: "unload", result: "success" })).to eq(1)
    end
  end

  # ── child_rss_bytes helper ───────────────────────────────────────────────────

  describe ".child_rss_bytes" do
    it "returns 0 when pid is nil" do
      expect(described_class.child_rss_bytes(nil)).to eq(0)
    end

    it "returns a non-negative integer for the current process pid" do
      expect(described_class.child_rss_bytes(Process.pid)).to be >= 0
    end
  end
end
