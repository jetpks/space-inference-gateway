# frozen_string_literal: true

RSpec.describe SpaceInferenceGateway::ErrorRelay::Oai do
  subject(:relay) { described_class.new }

  def do_relay(status, body)
    result = relay.relay(status, body)
    { status: result[0], body: result[2].first }
  end

  describe "#relay" do
    it "passes conformant OAI JSON body through verbatim" do
      body = '{"error":{"message":"bad request","type":"invalid_request_error"}}'
      r = do_relay(400, body)
      expect(r[:status]).to eq(400)
      expect(r[:body]).to eq(body)
    end

    it "wraps non-JSON body in upstream_error envelope" do
      r = do_relay(500, "server exploded")
      expect(r[:status]).to eq(500)
      parsed = JSON.parse(r[:body])
      expect(parsed.dig("error", "message")).to eq("server exploded")
      expect(parsed.dig("error", "type")).to eq("upstream_error")
    end
  end
end

RSpec.describe SpaceInferenceGateway::ErrorRelay::Mlx do
  subject(:relay) { described_class.new }

  def do_relay(status, body)
    result = relay.relay(status, body)
    { status: result[0], body: result[2].first }
  end

  let(:mlx_string_error) { '{"error":"Invalid JSON in request body: bad syntax"}' }

  describe "#relay — mlx string-error shape" do
    it "reshapes to a conformant OAI error object" do
      r = do_relay(400, mlx_string_error)
      parsed = JSON.parse(r[:body])
      expect(parsed.dig("error", "message")).to eq("Invalid JSON in request body: bad syntax")
      expect(parsed.dig("error", "type")).to be_a(String)
    end

    it "error value is a Hash with message+type, not a nested string" do
      r = do_relay(400, mlx_string_error)
      expect(JSON.parse(r[:body])["error"]).to be_a(Hash)
    end

    it "status code is preserved" do
      r = do_relay(400, mlx_string_error)
      expect(r[:status]).to eq(400)
    end
  end

  describe "#relay — falls through to Oai when body is not mlx string shape" do
    it "passes through conformant OAI body verbatim" do
      oai_body = '{"error":{"message":"already OAI","type":"api_error"}}'
      r = do_relay(500, oai_body)
      expect(r[:body]).to eq(oai_body)
    end

    it "wraps non-JSON body as upstream_error" do
      r = do_relay(502, "gateway timeout")
      expect(JSON.parse(r[:body]).dig("error", "type")).to eq("upstream_error")
    end

    it "error value as Hash triggers Oai passthrough" do
      hash_error = '{"error":{"message":"nested","type":"api_error"}}'
      r = do_relay(500, hash_error)
      expect(r[:body]).to eq(hash_error)
    end
  end

  # ── AC6: optiq error fixture (same {"error":"<string>"} shape) ───────────
  describe "#relay — optiq error400 fixture (AC6)" do
    let(:optiq_error) do
      File.read(File.join(File.expand_path("../fixtures/optiq", __dir__), "error400.json"))
    end

    it "reshapes optiq string error to conformant OAI envelope" do
      r = do_relay(400, optiq_error)
      expect(r[:status]).to eq(400)
      parsed = JSON.parse(r[:body])
      expect(parsed["error"]).to be_a(Hash)
      expect(parsed.dig("error", "message")).to include("Invalid JSON")
      expect(parsed.dig("error", "type")).to be_a(String)
    end
  end
end
