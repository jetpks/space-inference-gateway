# frozen_string_literal: true

RSpec.describe SpaceInferenceGateway::ErrorRelay::Oai do
  subject(:relay) { described_class.new }

  def do_relay(status, body, flavor:)
    result = relay.relay(status, body, flavor: flavor)
    { status: result[0], body: result[2].first }
  end

  describe "#relay flavor: :oai" do
    it "passes conformant OAI JSON body through verbatim" do
      body = '{"error":{"message":"bad request","type":"invalid_request_error"}}'
      r = do_relay(400, body, flavor: :oai)
      expect(r[:status]).to eq(400)
      expect(r[:body]).to eq(body)
    end

    it "wraps non-JSON body in upstream_error envelope" do
      r = do_relay(500, "server exploded", flavor: :oai)
      expect(r[:status]).to eq(500)
      parsed = JSON.parse(r[:body])
      expect(parsed.dig("error", "message")).to eq("server exploded")
      expect(parsed.dig("error", "type")).to eq("upstream_error")
    end
  end

  describe "#relay flavor: :ant" do
    it "extracts message from conformant OAI body into ANT envelope" do
      body = '{"error":{"message":"rate limited","type":"rate_limit_error"}}'
      r = do_relay(429, body, flavor: :ant)
      expect(r[:status]).to eq(429)
      parsed = JSON.parse(r[:body])
      expect(parsed["type"]).to eq("error")
      expect(parsed.dig("error", "message")).to eq("rate limited")
    end

    it "uses raw body as message when body is not JSON" do
      r = do_relay(503, "overloaded", flavor: :ant)
      expect(JSON.parse(r[:body]).dig("error", "message")).to eq("overloaded")
    end

    it "maps 429 to rate_limit_error" do
      r = do_relay(429, "x", flavor: :ant)
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("rate_limit_error")
    end

    it "maps 500 to api_error" do
      r = do_relay(500, "x", flavor: :ant)
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("api_error")
    end

    it "maps 401 to authentication_error" do
      r = do_relay(401, "x", flavor: :ant)
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("authentication_error")
    end

    it "maps unknown status to invalid_request_error" do
      r = do_relay(422, "x", flavor: :ant)
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("invalid_request_error")
    end
  end
end

RSpec.describe SpaceInferenceGateway::ErrorRelay::Mlx do
  subject(:relay) { described_class.new }

  def do_relay(status, body, flavor:)
    result = relay.relay(status, body, flavor: flavor)
    { status: result[0], body: result[2].first }
  end

  let(:mlx_string_error) { '{"error":"Invalid JSON in request body: bad syntax"}' }

  describe "#relay — mlx string-error shape" do
    it "reshapes to OAI error object for :oai flavor" do
      r = do_relay(400, mlx_string_error, flavor: :oai)
      parsed = JSON.parse(r[:body])
      expect(parsed.dig("error", "message")).to eq("Invalid JSON in request body: bad syntax")
      expect(parsed.dig("error", "type")).to be_a(String)
    end

    it "error value is a Hash with message+type, not a nested string" do
      r = do_relay(400, mlx_string_error, flavor: :oai)
      expect(JSON.parse(r[:body])["error"]).to be_a(Hash)
    end

    it "produces ANT error envelope for :ant flavor" do
      r = do_relay(400, mlx_string_error, flavor: :ant)
      parsed = JSON.parse(r[:body])
      expect(parsed["type"]).to eq("error")
      expect(parsed.dig("error", "message")).to eq("Invalid JSON in request body: bad syntax")
    end

    it "status code is preserved in both flavors" do
      r_oai = do_relay(400, mlx_string_error, flavor: :oai)
      r_ant = do_relay(400, mlx_string_error, flavor: :ant)
      expect(r_oai[:status]).to eq(400)
      expect(r_ant[:status]).to eq(400)
    end
  end

  describe "#relay — falls through to Oai when body is not mlx string shape" do
    it "passes through conformant OAI body verbatim for :oai" do
      oai_body = '{"error":{"message":"already OAI","type":"api_error"}}'
      r = do_relay(500, oai_body, flavor: :oai)
      expect(r[:body]).to eq(oai_body)
    end

    it "wraps non-JSON body as upstream_error for :oai" do
      r = do_relay(502, "gateway timeout", flavor: :oai)
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("upstream_error")
    end

    it "falls through for OAI body on :ant flavor, extracting message" do
      oai_body = '{"error":{"message":"real error","type":"api_error"}}'
      r = do_relay(500, oai_body, flavor: :ant)
      parsed = JSON.parse(r[:body])
      expect(parsed["type"]).to eq("error")
      expect(parsed.dig("error", "message")).to eq("real error")
    end

    it "error value as Hash triggers Oai passthrough" do
      hash_error = '{"error":{"message":"nested","type":"api_error"}}'
      r = do_relay(500, hash_error, flavor: :oai)
      expect(r[:body]).to eq(hash_error)
    end
  end
end
