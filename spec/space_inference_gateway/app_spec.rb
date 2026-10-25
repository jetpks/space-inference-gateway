# frozen_string_literal: true

require "rack/test"
require_relative "../support/fake_upstream_server"

RSpec.describe SpaceInferenceGateway::App do
  include Rack::Test::Methods
  include FakeUpstreamServer

  let(:oai_response)   { fixture("oai_ns.json") }
  let(:oai_s_response) { fixture("oai_s.txt") }

  let(:upstream_fn) do
    lambda do |path, _body|
      case path
      when "/v1/chat/completions" then [oai_response, 200, {}]
      else ["not found", 404, {}]
      end
    end
  end

  let(:app) { described_class.new(upstream_fn: upstream_fn, controller: app_fixture_controller) }

  # ── AC6: Route presence ───────────────────────────────────────────────────
  describe "GET /v1/models" do
    before { get "/v1/models" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "returns the advertised model" do
      body = JSON.parse(last_response.body)
      expect(body["object"]).to eq("list")
      expect(body["data"]).not_to be_empty
      expect(body["data"].first["id"]).to be_a(String)
    end
  end

  describe "POST /v1/chat/completions (non-stream)" do
    let(:request_body) { JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [{ role: "user", content: "hi" }] }) }

    before { post "/v1/chat/completions", request_body, "CONTENT_TYPE" => "application/json" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "returns a normalized OAI completion without <think> tags" do
      body = JSON.parse(last_response.body)
      content = body.dig("choices", 0, "message", "content")
      expect(content).not_to include("<think>")
    end

    it "AC6 — non-reasoning response schema-valid" do
      body   = JSON.parse(last_response.body)
      result = SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(body)
      expect(result).to be_success
    end
  end

  # mlx_lm.server validates the request "model" field against its loaded model id
  # (the HF repo id) and 404s unknown names to HuggingFace. The proxy rewrites the
  # client's alias to the registry entry's repo id before forwarding.
  describe "mlx model-field rewrite (OAI)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    it "rewrites the alias to the mlx repo id for the default mlx engine" do
      body = JSON.generate({ model: "qwen3-35b-a3b", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      expect(forwarded.length).to eq(1)
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["model"]).to eq("mlx-community/Qwen3.5-35B-A3B-4bit")
    end

    # Was: "rewrites the model field to the mlx-vlm repo id for unknown alias
    # (mlx-vlm default)". That asserted the fallback this replaces — an
    # unknown alias reaching the engine at all, rewritten to the DEFAULT
    # alias's repo id, is exactly how a request for one model got answered by
    # another with a 200 and nothing saying so.
    it "refuses an unknown alias instead of forwarding it to the default model" do
      body = JSON.generate({ model: "no-such-alias", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(404)
      expect(forwarded).to be_empty, "an unknown alias reached the engine"
      error = JSON.parse(last_response.body)["error"]
      expect(error["code"]).to eq("model_not_found")
      expect(error["param"]).to eq("model")
      expect(error["message"]).to include("no-such-alias")
    end

    it "refuses a request with no model field at all" do
      post "/v1/chat/completions", JSON.generate({ messages: [{ role: "user", content: "hi" }] }),
           "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(400)
      expect(forwarded).to be_empty
      expect(JSON.parse(last_response.body).dig("error", "type")).to eq("invalid_request_error")
    end

    it "normalizes the OpenAI 'developer' role to 'system' (mlx rejects developer)" do
      body = JSON.generate({
                             model: "qwen3-35b-a3b",
        messages: [
          { role: "developer", content: "you are helpful" },
          { role: "user", content: "hi" },
        ],
                           })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      roles = sent["messages"].map { |m| m["role"] }
      expect(roles).to eq(%w[system user])
    end

    it "folds max_completion_tokens into max_tokens (mlx engines read only max_tokens)" do
      # Ported from prod f17acc5 (I06): modern OAI clients (pi included) send
      # max_completion_tokens; mlx-vlm's schema only reads max_tokens and
      # silently defaults to 2048 when it's missing — xhigh thinking exhausts
      # that before the answer begins.
      body = JSON.generate({
                             model: "qwen3-35b-a3b",
        messages: [{ role: "user", content: "hi" }],
        max_completion_tokens: 4096,
                           })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["max_tokens"]).to eq(4096)
      expect(sent.key?("max_completion_tokens")).to be false
    end

    it "an explicit max_tokens always wins — max_completion_tokens is not folded over it" do
      body = JSON.generate({
                             model: "qwen3-35b-a3b",
        messages: [{ role: "user", content: "hi" }],
        max_completion_tokens: 100,
        max_tokens: 7,
                           })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["max_tokens"]).to eq(7)
      expect(sent["max_completion_tokens"]).to eq(100)
    end

    it "injects the registry stop_tokens for the default mlx model (hermes-4)" do
      body = JSON.generate({ model: "hermes-4-70b", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["stop"]).to include("<|eot_id|>")
    end

    it "merges client stop sequences with the registry stop_tokens" do
      body = JSON.generate({ model: "hermes-4-70b", messages: [{ role: "user", content: "hi" }], stop: ["END"] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["stop"]).to include("END", "<|eot_id|>")
    end

    it "does not inject stop_tokens for models without the config (qwen3)" do
      body = JSON.generate({ model: "qwen3-35b-a3b", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent.key?("stop")).to be false
    end
  end

  # ── Sampling penalty injection ────────────────────────────────────────────
  # On a fixture registry, not config/models.yml. These assert the BEHAVIOUR of
  # inject_sampling_penalties, which must keep working whether or not any
  # shipped alias currently declares penalties — and as of 2026-09-01 none do,
  # having been dropped from the a3b arms as wrong for code. Binding them to a
  # production alias is what broke them when that landed.
  describe "sampling penalty injection" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    let(:registry) do
      SpaceInferenceGateway::ModelRegistry.new(
        "default" => "penalty-arm",
        "models"  => {
          "penalty-arm" => {
            "engine" => "mlx-vlm", "model" => "fixture/penalty-arm", "port" => 8080,
            "penalties" => { "repetition_penalty" => 1.05, "repetition_context_size" => 64 },
          },
          "plain-arm" => {
            "engine" => "mlx-vlm", "model" => "fixture/plain-arm", "port" => 8080,
          },
        },
      )
    end

    let(:app) do
      supervisor = FakeUpstreamServer::FakeSupervisor.new("penalty-arm", "http://unused")
      controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)
      described_class.new(upstream_fn: upstream_fn, controller: controller)
    end

    def sent_for(body)
      post "/v1/chat/completions", JSON.generate(body), "CONTENT_TYPE" => "application/json"
      JSON.parse(forwarded.first[:body])
    end

    it "injects the alias's declared sampling penalties" do
      sent = sent_for({ model: "penalty-arm", messages: [{ role: "user", content: "hi" }] })

      expect(sent["repetition_penalty"]).to eq(1.05)
      expect(sent["repetition_context_size"]).to eq(64)
    end

    # A declared penalty is a default, not an override: mirrors how
    # reasoning_effort keeps a value the template accepts.
    it "lets a client's own penalty win over the alias default" do
      sent = sent_for({ model: "penalty-arm", messages: [{ role: "user", content: "hi" }],
                        repetition_penalty: 1.5, })

      expect(sent["repetition_penalty"]).to eq(1.5)
      expect(sent["repetition_context_size"]).to eq(64)
    end

    it "leaves an alias declaring no penalties untouched" do
      sent = sent_for({ model: "plain-arm", messages: [{ role: "user", content: "hi" }] })

      expect(sent).not_to have_key("repetition_penalty")
      expect(sent).not_to have_key("repetition_context_size")
    end
  end

  # ── Reasoning effort passthrough (OAI, mlx-vlm) ───────────────────────
  # On a local fixture registry: these assert inject_reasoning_effort's
  # behaviour, which must hold whatever the live fleet currently declares
  # (several arms carry reasoning_effort defaults; the fixture pins the
  # semantics so an ops retune can't silently narrow them).
  describe "reasoning effort passthrough (OAI, mlx-vlm)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    let(:registry) do
      SpaceInferenceGateway::ModelRegistry.new(
        "default" => "effort-arm",
        "models"  => {
          "effort-arm" => { "engine" => "mlx-vlm", "model" => "fixture/effort", "port" => 8080,
                             "reasoning_effort" => "medium",
                             "reasoning_effort_values" => %w[high medium low none], },
          "plain-arm" => { "engine" => "mlx-vlm", "model" => "fixture/plain", "port" => 8080 },
          "strict-arm" => { "engine" => "mlx-vlm", "model" => "fixture/strict", "port" => 8080,
                             "preserve_thinking" => false, },
        },
      )
    end

    let(:app) do
      supervisor = FakeUpstreamServer::FakeSupervisor.new("effort-arm", "http://unused")
      controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)
      described_class.new(upstream_fn: upstream_fn, controller: controller)
    end

    def sent_for(body)
      post "/v1/chat/completions", JSON.generate(body), "CONTENT_TYPE" => "application/json"
      JSON.parse(forwarded.last[:body])
    end

    it "injects the alias default when the client sends no effort" do
      sent = sent_for({ model: "effort-arm", messages: [{ role: "user", content: "hi" }] })
      expect(sent["reasoning_effort"]).to eq("medium")
    end

    it "passes a requested effort the alias's template allows" do
      sent = sent_for({ model: "effort-arm", messages: [{ role: "user", content: "hi" }],
                        reasoning_effort: "high", })
      expect(sent["reasoning_effort"]).to eq("high")
    end

    it "coerces a requested effort the template rejects to the alias default" do
      sent = sent_for({ model: "effort-arm", messages: [{ role: "user", content: "hi" }],
                        reasoning_effort: "xhigh", })
      expect(sent["reasoning_effort"]).to eq("medium")
    end

    it "reads the nested Responses-API form and rewrites both fields" do
      sent = sent_for({ model: "effort-arm", messages: [{ role: "user", content: "hi" }],
                        reasoning: { effort: "low" }, })
      expect(sent["reasoning_effort"]).to eq("low")
      expect(sent.dig("reasoning", "effort")).to eq("low")
    end

    it "leaves a requested disabled effort alone (mlx-vlm reads it as thinking off)" do
      sent = sent_for({ model: "effort-arm", messages: [{ role: "user", content: "hi" }],
                        reasoning_effort: "none", })
      expect(sent["reasoning_effort"]).to eq("none")
    end

    it "leaves aliases without a reasoning_effort default untouched" do
      sent = sent_for({ model: "plain-arm", messages: [{ role: "user", content: "hi" }] })
      expect(sent).not_to have_key("reasoning_effort")
    end

    it "strips assistant reasoning from history when preserve_thinking is false, keeping the text" do
      sent = sent_for({
                        model: "strict-arm",
        messages: [
          { role: "user", content: "a" },
          { role: "assistant", content: "answer", reasoning_content: "long chain of thought" },
          { role: "user", content: "b" },
        ],
                      })
      assistant = sent["messages"].find { |m| m["role"] == "assistant" }
      expect(assistant["content"]).to eq("answer")
      expect(JSON.generate(sent)).not_to include("long chain of thought")
    end
  end

  # ── AC3: optiq engine path ────────────────────────────────────────────────
  describe "optiq engine — OAI path (AC3)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    it "does not rewrite model field for optiq engine (single-model accepts any label)" do
      body = JSON.generate({ model: "qwen3-27b-optiq", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["model"]).to eq("qwen3-27b-optiq")
    end

    it "applies developer→system role normalization for optiq engine" do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [
          { role: "developer", content: "be helpful" },
          { role: "user",      content: "hi" },
        ],
                           })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["messages"].map { |m| m["role"] }).to eq(%w[system user])
    end
  end

  # ── I04: mlx-vlm joins the OAI-upstream engine class ──────────────────────
  describe "mlx-vlm engine — OAI paths (I04)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    it "rewrites the alias to the mlx-vlm repo id" do
      body = JSON.generate({ model: "qwen3.8-27b-mxfp8-concurrent1", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["model"]).to eq("mlx-community/Qwen3.8-27B-mxfp8")
    end

    it "normalizes the OpenAI 'developer' role to 'system' (mlx-vlm rejects developer)" do
      body = JSON.generate({
                             model: "qwen3.8-27b-mxfp8-concurrent1",
        messages: [
          { role: "developer", content: "you are helpful" },
          { role: "user", content: "hi" },
        ],
                           })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      roles = sent["messages"].map { |m| m["role"] }
      expect(roles).to eq(%w[system user])
    end
  end

  describe "optiq string-error relay (AC3 + AC6)" do
    let(:upstream_fn) { ->(_path, _body) { ['{"error":"bad json body"}', 400, {}] } }

    before do
      post "/v1/chat/completions",
           JSON.generate({ model: "qwen3-27b-optiq", messages: [] }),
           "CONTENT_TYPE" => "application/json"
    end

    it "reshapes optiq string error to conformant OAI envelope" do
      expect(last_response.status).to eq(400)
      parsed = JSON.parse(last_response.body)
      expect(parsed.dig("error", "message")).to eq("bad json body")
      expect(parsed["error"]).to be_a(Hash)
    end
  end

  describe "unknown route" do
    before { get "/v1/unknown" }

    it "returns 404" do
      expect(last_response.status).to eq(404)
    end
  end

  # ── Removed surface (BRIEF §2): the second-wire routes are gone ───────────
  describe "removed routes (single wire)" do
    it "POST /v1/messages returns the standard 404 body" do
      body = JSON.generate({ model: "any", messages: [{ role: "user", content: "hi" }], max_tokens: 10 })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)).to eq({ "error" => { "message" => "Not found", "type" => "invalid_request_error" } })
    end

    it "POST /v1/messages/count_tokens returns the standard 404 body" do
      body = JSON.generate({ model: "any", messages: [{ role: "user", content: "hi" }] })
      post "/v1/messages/count_tokens", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)).to eq({ "error" => { "message" => "Not found", "type" => "invalid_request_error" } })
    end

    it "a removed-route request is never forwarded upstream" do
      forwarded = []
      spy_fn = lambda do |path, body|
        forwarded << { path: path, body: body }
        [oai_response, 200, {}]
      end
      app = described_class.new(upstream_fn: spy_fn)
      Rack::MockRequest.new(app).post("/v1/messages", input: JSON.generate({ model: "any", messages: [] }),
                                                   "CONTENT_TYPE" => "application/json",)
      expect(forwarded).to be_empty
    end
  end

  # ── AC6: Streaming OAI (fake upstream) ────────────────────────────────────
  describe "POST /v1/chat/completions (stream)" do
    let(:upstream_fn) do
      lambda do |path, _body|
        case path
        when "/v1/chat/completions" then [oai_s_response, 200, {}]
        else ["not found", 404, {}]
        end
      end
    end

    let(:request_body) { JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [], stream: true }) }

    before { post "/v1/chat/completions", request_body, "CONTENT_TYPE" => "application/json" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "response content-type is text/event-stream" do
      expect(last_response.headers["content-type"]).to include("text/event-stream")
    end

    it "ends with data: [DONE]" do
      expect(last_response.body.strip).to end_with("data: [DONE]")
    end
  end

  # ── Prometheus /metrics route (AC1, AC2) ──────────────────────────────────────

  describe "GET /metrics" do
    before do
      SpaceInferenceGateway::Metrics.reset_all
      get "/metrics"
    end

    it "returns HTTP 200" do
      expect(last_response.status).to eq(200)
    end

    it "content-type is Prometheus text format" do
      ct = last_response.headers["content-type"]
      expect(ct).to include("text/plain")
      expect(ct).to include("version=0.0.4")
    end

    it "body has # HELP and # TYPE for sig_requests_total" do
      expect(last_response.body).to include("# HELP sig_requests_total")
      expect(last_response.body).to include("# TYPE sig_requests_total counter")
    end
  end

  describe "request instrumentation (AC2)" do
    before { SpaceInferenceGateway::Metrics.reset_all }

    it "increments sig_requests_total for OAI non-stream" do
      body = JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "false" })).to eq(1)
    end

    it "increments sig_requests_total for OAI stream (legacy-seam path)" do
      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = described_class.new(upstream_fn: streaming_fn, controller: app_fixture_controller)
      body = JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [], stream: true })
      post_response = Rack::MockRequest.new(streaming_app).post(
        "/v1/chat/completions", input: body, "CONTENT_TYPE" => "application/json",
      )
      expect(post_response.status).to eq(200)
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "true" })).to eq(1)
    end
    it "exactly +1 for OAI non-stream and +1 for OAI stream after separate requests (AC2)" do
      ns_body = JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [] })
      post "/v1/chat/completions", ns_body, "CONTENT_TYPE" => "application/json"

      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = described_class.new(upstream_fn: streaming_fn, controller: app_fixture_controller)
      s_body = JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [], stream: true })
      Rack::MockRequest.new(streaming_app).post(
        "/v1/chat/completions", input: s_body, "CONTENT_TYPE" => "application/json",
      )

      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "false" })).to eq(1)
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "true" })).to eq(1)
    end
  end

  describe "upstream error passthrough" do
    let(:incident_body) do
      '{"error":{"code":400,"message":"Cannot have 2 or more assistant messages at the end of the list.","type":"invalid_request_error"}}'
    end

    describe "OAI non-stream — upstream 400 relayed verbatim (AC1)" do
      let(:upstream_fn) { ->(_path, _body) { [incident_body, 400, {}] } }

      before do
        post "/v1/chat/completions",
             JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [] }),
             "CONTENT_TYPE" => "application/json"
      end

      it "returns HTTP 400" do
        expect(last_response.status).to eq(400)
      end

      it "returns application/json content-type" do
        expect(last_response.headers["content-type"]).to include("application/json")
      end

      it "body is byte-verbatim the upstream JSON" do
        expect(last_response.body).to eq(incident_body)
      end
    end

    describe "OAI non-stream — unparseable upstream body wrapped in error envelope (AC5)" do
      let(:upstream_fn) { ->(_path, _body) { ["boom", 500, {}] } }

      before do
        post "/v1/chat/completions",
             JSON.generate({ model: "qwen3.8-flash-next-oq3", messages: [] }),
             "CONTENT_TYPE" => "application/json"
      end

      it "returns HTTP 500" do
        expect(last_response.status).to eq(500)
      end

      it "wraps non-JSON body in OAI error envelope" do
        body = JSON.parse(last_response.body)
        expect(body.dig("error", "message")).to eq("boom")
        expect(body.dig("error", "type")).to eq("upstream_error")
      end
    end
  end
end
