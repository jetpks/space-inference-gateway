# frozen_string_literal: true

require "rack/test"

RSpec.describe SpaceInferenceGateway::App do
  include Rack::Test::Methods

  let(:oai_response)   { fixture("oai_ns.json") }
  let(:ant_response)   { fixture("ant_ns.json") }
  let(:oai_s_response) { fixture("oai_s.txt") }

  let(:upstream_fn) do
    lambda do |path, _body|
      case path
      when "/v1/chat/completions" then [oai_response, 200, {}]
      when "/v1/messages"         then [ant_response, 200, {}]
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

    it "passes model field through unchanged for unknown alias on optiq default (single-model)" do
      # The default alias (qwen3-27b-optiq, engine: optiq) does not rewrite the
      # "model" field — optiq's single-model mode accepts any label value.
      body = JSON.generate({ model: "no-such-alias", messages: [{ role: "user", content: "hi" }] })
      post "/v1/chat/completions", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["model"]).to eq("no-such-alias")
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

  describe "optiq engine — ANT path synthesizes from OAI upstream (AC3)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    it "routes /v1/messages for optiq to /v1/chat/completions (OAI synthesis)" do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [{ role: "user", content: "hi" }],
        max_tokens: 100,
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      expect(forwarded.first[:path]).to eq("/v1/chat/completions")
    end
  end

  # ── I10: ANT request translation (tools/tool_result/tool_use -> OAI) ─────
  describe "ANT request translation for the optiq engine (I10 AC1-AC3)" do
    let(:forwarded) { [] }
    let(:upstream_fn) do
      lambda do |path, body|
        forwarded << { path: path, body: body }
        [fixture("oai_ns.json"), 200, {}]
      end
    end

    it "translates ANT tools into OAI tools (AC1)", :tool_calls do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [{ role: "user", content: "weather?" }],
        max_tokens: 100,
        tools: [{
          name: "get_weather", description: "Get the weather for a city",
          input_schema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] },
        }],
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["tools"]).to eq([{
                                    "type" => "function",
                                    "function" => {
                                      "name" => "get_weather", "description" => "Get the weather for a city",
          "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } },
                             "required" => ["city"], },
                                    },
                                  }])
    end

    it "translates a tool_result block into a separate OAI tool message (AC2)", :tool_calls do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [
          { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "sunny, 25C" }] },
        ],
        max_tokens: 100,
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent["messages"]).to eq([{ "role" => "tool", "tool_call_id" => "toolu_1", "content" => "sunny, 25C" }])
    end

    it "flattens array-of-text-block tool_result content (AC2)", :tool_calls do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [
          { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1",
                                      content: [{ type: "text", text: "sunny, 25C" }], }], },
        ],
        max_tokens: 100,
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      sent = JSON.parse(forwarded.first[:body])
      expect(sent.dig("messages", 0, "content")).to eq("sunny, 25C")
    end

    it "translates assistant tool_use + text into OAI content + tool_calls (AC3)", :tool_calls do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [
          { role: "user", content: "weather?" },
          { role: "assistant", content: [
            { type: "text", text: "Let me check." },
            { type: "tool_use", id: "toolu_1", name: "get_weather", input: { city: "Tokyo" } },
          ], },
          { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "sunny" }] },
        ],
        max_tokens: 100,
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      sent      = JSON.parse(forwarded.first[:body])
      assistant = sent["messages"].find { |m| m["role"] == "assistant" }
      expect(assistant["content"]).to eq("Let me check.")
      expect(assistant["tool_calls"]).to eq([{
                                              "id" => "toolu_1", "type" => "function",
        "function" => { "name" => "get_weather", "arguments" => JSON.generate({ "city" => "Tokyo" }) },
                                            }])
    end
  end

  # ── I10: end-to-end streaming tool_use synthesis (AC7) ───────────────────
  describe "ANT streaming tool_use synthesis from an optiq tool_calls SSE stream (I10 AC7)" do
    OPTIQ_TOOL_FIXTURE_PATH = File.expand_path("../fixtures/optiq", __dir__) unless defined?(OPTIQ_TOOL_FIXTURE_PATH)

    let(:tool_stream_sse) { File.read(File.join(OPTIQ_TOOL_FIXTURE_PATH, "tool-stream.txt")) }
    let(:upstream_fn) { ->(_path, _body) { [tool_stream_sse, 200, {}] } }

    let(:events) do
      last_response.body.split("\n\n").reject(&:empty?).map do |blk|
        lines = blk.lines.map(&:strip)
        { event: lines.find { |l| l.start_with?("event:") }.sub(/\Aevent:\s*/, ""),
          data:  JSON.parse(lines.find { |l| l.start_with?("data:") }.sub(/\Adata:\s*/, "")), }
      end
    end

    before do
      body = JSON.generate({
                             model: "qwen3-27b-optiq",
        messages: [{ role: "user", content: "what's the weather in Tokyo?" }],
        max_tokens: 100,
        stream: true,
                           })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
    end

    it "returns 200 text/event-stream", :tool_calls do
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to include("text/event-stream")
    end

    it "yields an ANT tool_use content_block_start", :tool_calls do
      starts = events.select do |e|
        e[:event] == "content_block_start" && e[:data].dig("content_block", "type") == "tool_use"
      end
      expect(starts.length).to eq(1)
      expect(starts.first[:data].dig("content_block", "name")).to eq("get_weather")
      expect(starts.first[:data].dig("content_block", "id")).to eq("toolu_call_9f8a2b")
    end

    it "yields input_json_delta events for the tool_use block", :tool_calls do
      deltas = events.select { |e| e[:event] == "content_block_delta" && e[:data].dig("delta", "type") == "input_json_delta" }
      expect(deltas).not_to be_empty
    end

    it "message_delta stop_reason is tool_use", :tool_calls do
      delta = events.reverse.find { |e| e[:event] == "message_delta" }
      expect(delta[:data].dig("delta", "stop_reason")).to eq("tool_use")
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

  describe "POST /v1/messages/count_tokens" do
    it "returns 200 with an integer input_tokens estimate" do
      body = JSON.generate({ model: "any", messages: [{ role: "user", content: "a" * 40 }] })
      post "/v1/messages/count_tokens", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["input_tokens"]).to be_an(Integer)
      expect(parsed["input_tokens"]).to eq(10) # 40 chars / 4
    end

    it "handles string and array content shapes" do
      body = JSON.generate({
                             model: "any",
        system: "eight chars",
        messages: [{ role: "user", content: [{ type: "text", text: "eight more" }] }],
                           })
      post "/v1/messages/count_tokens", body, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["input_tokens"]).to eq(6) # 21 chars / 4 = 5.25 -> ceil 6
    end
  end

  describe "POST /v1/messages (non-stream)" do
    let(:request_body) { JSON.generate({ model: "any", messages: [{ role: "user", content: "hi" }], max_tokens: 100 }) }

    before { post "/v1/messages", request_body, "CONTENT_TYPE" => "application/json" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "returns thinking + text content blocks" do
      body  = JSON.parse(last_response.body)
      types = body["content"].map { |b| b["type"] }
      expect(types).to include("thinking")
      expect(types).to include("text")
    end
  end

  describe "unknown route" do
    before { get "/v1/unknown" }

    it "returns 404" do
      expect(last_response.status).to eq(404)
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
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "oai", stream: "false" })).to eq(1)
    end

    it "increments sig_requests_total for OAI stream (legacy-seam path)" do
      streaming_fn = ->(_path, _body) { [oai_s_response, 200, {}] }
      streaming_app = described_class.new(upstream_fn: streaming_fn)
      body = JSON.generate({ model: "any", messages: [], stream: true })
      post_response = Rack::MockRequest.new(streaming_app).post(
        "/v1/chat/completions", input: body, "CONTENT_TYPE" => "application/json",
      )
      expect(post_response.status).to eq(200)
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "oai", stream: "true" })).to eq(1)
    end

    it "increments sig_requests_total for ANT non-stream" do
      body = JSON.generate({ model: "any", messages: [], max_tokens: 100 })
      post "/v1/messages", body, "CONTENT_TYPE" => "application/json"
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "ant", stream: "false" })).to eq(1)
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

      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "oai", stream: "false" })).to eq(1)
      expect(SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "oai", stream: "true" })).to eq(1)
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

    describe "ANT non-stream — upstream 400 wrapped in Anthropic envelope (AC3)" do
      let(:upstream_fn) { ->(_path, _body) { [incident_body, 400, {}] } }

      before do
        post "/v1/messages",
             JSON.generate({ model: "any", messages: [], max_tokens: 100 }),
             "CONTENT_TYPE" => "application/json"
      end

      it "returns HTTP 400" do
        expect(last_response.status).to eq(400)
      end

      it "wraps in Anthropic error envelope with invalid_request_error type" do
        body = JSON.parse(last_response.body)
        expect(body["type"]).to eq("error")
        expect(body.dig("error", "type")).to eq("invalid_request_error")
        expect(body.dig("error", "message")).to eq(
          "Cannot have 2 or more assistant messages at the end of the list.",
        )
      end
    end

    describe "ANT non-stream — upstream 503 maps to api_error (AC3 spot-check)" do
      let(:upstream_fn) { ->(_path, _body) { ['{"error":{"message":"overloaded"}}', 503, {}] } }

      before do
        post "/v1/messages",
             JSON.generate({ model: "any", messages: [], max_tokens: 100 }),
             "CONTENT_TYPE" => "application/json"
      end

      it "returns HTTP 503" do
        expect(last_response.status).to eq(503)
      end

      it "maps 5xx to api_error type" do
        expect(JSON.parse(last_response.body).dig("error", "type")).to eq("api_error")
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

    describe "ANT non-stream — unparseable upstream body wrapped in ANT error envelope (AC5)" do
      let(:upstream_fn) { ->(_path, _body) { ["boom", 500, {}] } }

      before do
        post "/v1/messages",
             JSON.generate({ model: "any", messages: [], max_tokens: 100 }),
             "CONTENT_TYPE" => "application/json"
      end

      it "returns HTTP 500" do
        expect(last_response.status).to eq(500)
      end

      it "wraps non-JSON body in ANT error envelope" do
        body = JSON.parse(last_response.body)
        expect(body["type"]).to eq("error")
        expect(body.dig("error", "type")).to eq("api_error")
        expect(body.dig("error", "message")).to eq("boom")
      end
    end
  end
end
