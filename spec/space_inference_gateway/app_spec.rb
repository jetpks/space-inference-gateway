# frozen_string_literal: true

require "rack/test"

RSpec.describe SpaceInferenceGateway::App do
  include Rack::Test::Methods

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

  let(:app) { described_class.new(upstream_fn: upstream_fn) }

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
    let(:request_body) { JSON.generate({ model: "any", messages: [{ role: "user", content: "hi" }] }) }

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

    it "rewrites the model field to the mlx-vlm repo id for unknown alias (mlx-vlm default)" do
      # The default alias (qwen3.8-27b-mxfp8-concurrent1, engine: mlx-vlm) is what an unknown
      # alias falls back to. mlx-vlm validates the "model" field against its
      # loaded model the same way mlx does, so the fallback must rewrite it too —
      # forwarding the unresolved alias would evict the resident checkpoint.
      body = JSON.generate({ model: "no-such-alias", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["model"]).to eq("mlx-community/Qwen3.8-27B-mxfp8")
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

    let(:request_body) { JSON.generate({ model: "any", messages: [], stream: true }) }

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
      body = JSON.generate({ model: "any", messages: [] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "false" })).to eq(1)
    end

    it "increments sig_requests_total for OAI stream (legacy-seam path)" do
      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = described_class.new(upstream_fn: streaming_fn)
      body = JSON.generate({ model: "any", messages: [], stream: true })
      post_response = Rack::MockRequest.new(streaming_app).post(
        "/v1/chat/completions", input: body, "CONTENT_TYPE" => "application/json",
      )
      expect(post_response.status).to eq(200)
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { stream: "true" })).to eq(1)
    end
    it "exactly +1 for OAI non-stream and +1 for OAI stream after separate requests (AC2)" do
      ns_body = JSON.generate({ model: "any", messages: [] })
      post "/v1/chat/completions", ns_body, "CONTENT_TYPE" => "application/json"

      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = described_class.new(upstream_fn: streaming_fn)
      s_body = JSON.generate({ model: "any", messages: [], stream: true })
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
             JSON.generate({ model: "any", messages: [] }),
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
             JSON.generate({ model: "any", messages: [] }),
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
