# frozen_string_literal: true

require "rack/test"

RSpec.describe LocalInferenceProxy::App do
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
      result = LocalInferenceProxy::Schemas::OAI_COMPLETION.call(body)
      expect(result).to be_success
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
end
