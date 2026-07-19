# frozen_string_literal: true

require "rack/test"
require_relative "../support/fake_upstream_server"

# I09: generation phase, streamed deltas, time-to-first-token, usage tokens,
# stop reasons. Streaming lifecycle assertions drive the real Rack surface
# (FakeUpstreamServer + boot_proxy, no mock/stub of App/StreamBody) so the
# phase gauge and TTFT histogram are exercised through the actual
# open_stream/StreamBody bracket. Channel/usage/stop routing is exercised
# directly against the normalizers + a real GenerationObserver, since that is
# the public seam the app layer itself uses — no mock/stub of the class under
# test.
RSpec.describe "Telemetry metrics (I09)" do
  include Rack::Test::Methods
  include FakeUpstreamServer

  def metrics
    SpaceInferenceGateway::Metrics
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  let(:optiq_tool_stream)   { File.read(File.join(File.expand_path("../fixtures/optiq", __dir__), "tool-stream.txt")) }
  let(:optiq_plain_stream)  { File.read(File.join(File.expand_path("../fixtures/optiq", __dir__), "stream.txt")) }
  let(:mlx_stream)          { File.read(File.join(File.expand_path("../fixtures/mlx", __dir__), "stream.txt")) }
  let(:ant_native_stream)   { fixture("ant_s.txt") }

  let(:oai_ns_response) { fixture("oai_ns.json") }
  let(:ant_ns_response) { fixture("ant_ns.json") }

  def as_body(text)
    Enumerator.new { |y| y << text }
  end

  # A controller whose default alias has no mlx/optiq engine, so handle_ant
  # takes the true ANT-native branch instead of routing through handle_ant_mlx
  # (config/models.yml's real aliases are all mlx/optiq).
  def non_mlx_app(upstream_fn)
    supervisor = FakeUpstreamServer::FakeSupervisor.new("diffusiongemma", "http://unused")
    controller = SpaceInferenceGateway::ModelController.new(registry: fixture_registry, supervisor: supervisor)
    SpaceInferenceGateway::App.new(upstream_fn: upstream_fn, controller: controller)
  end

  before { metrics.reset_all }

  # ── AC1 — registry + boot-time initialization ───────────────────────────

  describe "registry" do
    it "defines all five new metric families" do
      names = metrics::REGISTRY.metrics.map(&:name)
      expect(names).to include(
        :sig_generation_phase,
        :sig_stream_deltas_total,
        :sig_time_to_first_token_seconds,
        :sig_usage_tokens_total,
        :sig_generation_stops_total,
      )
    end

    it "initializes both phase gauge label values to 0 at boot" do
      expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(0)
      expect(metrics::GENERATION_PHASE.get(labels: { phase: "decode" })).to eq(0)
    end
  end

  describe "GET /metrics" do
    let(:app) { SpaceInferenceGateway::App.new(upstream_fn: ->(_p, _b) { [oai_ns_response, 200, {}] }) }

    it "renders all five new families" do
      get "/metrics"
      %w[sig_generation_phase sig_stream_deltas_total sig_time_to_first_token_seconds
         sig_usage_tokens_total sig_generation_stops_total].each do |name|
        expect(last_response.body).to include("# TYPE #{name}")
      end
    end
  end

  # ── AC2 — phase lifecycle + TTFT, driven through the real Rack surface ──

  describe "phase lifecycle + TTFT (real streaming)" do
    around do |example|
      Async do |task|
        @task = task
        example.run
      end
    end

    it "open->prefill+1, first delta->decode (TTFT observed once), close decrements decode" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          @task.sleep(0.2) # headers only — proves the +1 lands before any delta
          http_chunk(sock, %(data: {"id":"x","choices":[{"index":0,"delta":{"content":"hi"}}]}\n\n))
          http_chunk(sock, %(data: {"id":"x","choices":[{"index":0,"finish_reason":"stop","delta":{}}]}\n\n))
          end_chunks(sock)
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 5)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)
        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(200)
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(1)
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "decode" })).to eq(0)

          nil while response.body.read # drain to natural completion

          @task.with_timeout(3) { @task.sleep(0.05) until metrics::ACTIVE_GENERATIONS.get.zero? }
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(0)
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "decode" })).to eq(0)

          ttft = metrics::TIME_TO_FIRST_TOKEN.get(labels: { flavor: "oai" })
          expect(ttft["+Inf"]).to eq(1)
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end

    it "abandon while still in prefill (no delta ever arrives) decrements prefill only" do
      stub_const("SpaceInferenceGateway::App::KEEPALIVE_INTERVAL", 1)

      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream_sock = nil
        upstream.accept do |sock|
          upstream_sock = sock
          sse_headers(sock)
          @task.sleep(60) # stall in prefill — no delta ever arrives
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 30)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)
        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(200)
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(1)

          response.close
          client.close
          expect(upstream.observe_close(upstream_sock, timeout: 5)).to be true

          @task.with_timeout(3) { @task.sleep(0.05) until metrics::ACTIVE_GENERATIONS.get.zero? }
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(0)
          expect(metrics::GENERATION_PHASE.get(labels: { phase: "decode" })).to eq(0)
          expect(metrics::TIME_TO_FIRST_TOKEN.get(labels: { flavor: "oai" })["+Inf"]).to eq(0)
        ensure
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end
  end

  describe "non-stream never moves the phase gauge" do
    let(:app) { SpaceInferenceGateway::App.new(upstream_fn: ->(_p, _b) { [oai_ns_response, 200, {}] }) }

    it "leaves both phase labels at 0" do
      post "/v1/chat/completions", JSON.generate({ model: "any", messages: [] }), "CONTENT_TYPE" => "application/json"
      expect(metrics::GENERATION_PHASE.get(labels: { phase: "prefill" })).to eq(0)
      expect(metrics::GENERATION_PHASE.get(labels: { phase: "decode" })).to eq(0)
    end
  end

  # ── AC3 — per-channel delta routing, all three streaming paths ─────────

  describe "sig_stream_deltas_total — channel routing" do
    it "OAI upstream path (OaiNormalizer#stream_to_sse): reasoning, content, tool_args" do
      normalizer = SpaceInferenceGateway::OaiNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "oai", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(optiq_tool_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "oai", channel: "reasoning" })).to be >= 1
      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "oai", channel: "content" })).to be >= 1
      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "oai", channel: "tool_args" })).to be >= 1
    end

    it "mlx/optiq-derived ANT path (AntNormalizer#stream_to_sse_from_oai): reasoning, content, tool_args" do
      normalizer = SpaceInferenceGateway::AntNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "ant", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse_from_oai(as_body(optiq_tool_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "ant", channel: "reasoning" })).to be >= 1
      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "ant", channel: "content" })).to be >= 1
      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "ant", channel: "tool_args" })).to be >= 1
    end

    it "ANT-native path (AntNormalizer#stream_to_sse): content" do
      normalizer = SpaceInferenceGateway::AntNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "ant", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(ant_native_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::STREAM_DELTAS.get(labels: { flavor: "ant", channel: "content" })).to be >= 1
    end
  end

  # ── AC3 — stop reasons, verbatim, streaming + non-stream ────────────────

  describe "sig_generation_stops_total" do
    it "streaming OAI-upstream path records the raw OAI finish_reason verbatim (oai flavor)" do
      normalizer = SpaceInferenceGateway::OaiNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "oai", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(optiq_tool_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::GENERATION_STOPS.get(labels: { flavor: "oai", stop_reason: "tool_calls" })).to eq(1)
    end

    it "streaming mlx/optiq-derived ANT path records the raw OAI finish_reason verbatim (ant flavor)" do
      normalizer = SpaceInferenceGateway::AntNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "ant", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse_from_oai(as_body(optiq_tool_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::GENERATION_STOPS.get(labels: { flavor: "ant", stop_reason: "tool_calls" })).to eq(1)
    end

    it "streaming ANT-native path records the upstream stop_reason verbatim" do
      normalizer = SpaceInferenceGateway::AntNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "ant", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(ant_native_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::GENERATION_STOPS.get(labels: { flavor: "ant", stop_reason: "end_turn" })).to eq(1)
    end

    it "non-stream OAI flavor records finish_reason verbatim (stop)" do
      app = SpaceInferenceGateway::App.new(upstream_fn: ->(_p, _b) { [oai_ns_response, 200, {}] })
      Rack::Test::Session.new(Rack::MockSession.new(app)).post(
        "/v1/chat/completions", JSON.generate({ model: "any", messages: [] }), "CONTENT_TYPE" => "application/json",
      )
      expect(metrics::GENERATION_STOPS.get(labels: { flavor: "oai", stop_reason: "stop" })).to eq(1)
    end

    it "non-stream ANT-native flavor records stop_reason verbatim (end_turn)" do
      app = non_mlx_app(->(_p, _b) { [ant_ns_response, 200, {}] })
      Rack::Test::Session.new(Rack::MockSession.new(app)).post(
        "/v1/messages", JSON.generate({ model: "diffusiongemma", messages: [], max_tokens: 100 }),
        "CONTENT_TYPE" => "application/json",
      )
      expect(metrics::GENERATION_STOPS.get(labels: { flavor: "ant", stop_reason: "end_turn" })).to eq(1)
    end
  end

  # ── AC3 — usage tokens: upstream-reported only, never fabricated ───────

  describe "sig_usage_tokens_total" do
    it "non-stream OAI flavor increments from upstream usage verbatim" do
      app = SpaceInferenceGateway::App.new(upstream_fn: ->(_p, _b) { [oai_ns_response, 200, {}] })
      Rack::Test::Session.new(Rack::MockSession.new(app)).post(
        "/v1/chat/completions", JSON.generate({ model: "any", messages: [] }), "CONTENT_TYPE" => "application/json",
      )
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "prompt" })).to eq(34)
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "completion" })).to eq(246)
    end

    it "non-stream ANT-native flavor increments from upstream usage verbatim" do
      app = non_mlx_app(->(_p, _b) { [ant_ns_response, 200, {}] })
      Rack::Test::Session.new(Rack::MockSession.new(app)).post(
        "/v1/messages", JSON.generate({ model: "diffusiongemma", messages: [], max_tokens: 100 }),
        "CONTENT_TYPE" => "application/json",
      )
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "ant", kind: "prompt" })).to eq(29)
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "ant", kind: "completion" })).to eq(162)
    end

    it "streaming optiq upstream carries a final usage chunk — recorded (oai flavor)" do
      normalizer = SpaceInferenceGateway::OaiNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "oai", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(optiq_plain_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "prompt" })).to eq(25)
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "completion" })).to eq(246)
    end

    it "streaming mlx upstream never sends usage — contributes nothing (no fabrication)" do
      normalizer = SpaceInferenceGateway::OaiNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "oai", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(mlx_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "prompt" })).to eq(0)
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "oai", kind: "completion" })).to eq(0)
    end

    it "streaming ANT-native path reads final usage from message_delta only" do
      normalizer = SpaceInferenceGateway::AntNormalizer.new(advertised_model: "m")
      observer   = SpaceInferenceGateway::GenerationObserver.new(flavor: "ant", t0: monotonic_now)
      sse = []
      normalizer.stream_to_sse(as_body(ant_native_stream), observer: observer) { |chunk| sse << chunk }

      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "ant", kind: "prompt" })).to eq(24)
      expect(metrics::USAGE_TOKENS.get(labels: { flavor: "ant", kind: "completion" })).to eq(119)
    end
  end
end
