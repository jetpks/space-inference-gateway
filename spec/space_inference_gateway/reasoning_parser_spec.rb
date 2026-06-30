# frozen_string_literal: true

RSpec.describe SpaceInferenceGateway::ReasoningParser do
  subject(:parser) { described_class.new }

  def full_extract(parser, *chunks)
    results = chunks.map { |c| parser.push(c) }
    results << parser.flush
    {
      visible:  results.map { |r| r[:visible] }.join,
      thinking: results.map { |r| r[:thinking] }.join,
    }
  end

  describe "#push / #flush — basic extraction" do
    it "extracts think block and visible text in a single chunk" do
      r = full_extract(parser, "<think>inner thought</think>visible text")
      expect(r[:thinking]).to eq("inner thought")
      expect(r[:visible]).to eq("visible text")
    end

    it "passes through text with no think tags" do
      r = full_extract(parser, "just normal text")
      expect(r[:visible]).to eq("just normal text")
      expect(r[:thinking]).to be_empty
    end

    it "passes through empty input" do
      r = full_extract(parser, "")
      expect(r[:visible]).to be_empty
      expect(r[:thinking]).to be_empty
    end

    it "does not leak <think> or </think> into visible" do
      r = full_extract(parser, "<think>thought</think>visible")
      expect(r[:visible]).not_to include("<think>")
      expect(r[:visible]).not_to include("</think>")
    end
  end

  describe "AC5 — partial tag across chunk boundaries" do
    it "handles <think> split across two chunks" do
      r = full_extract(parser, "<thi", "nk>some thought</think>visible")
      expect(r[:thinking]).to eq("some thought")
      expect(r[:visible]).to eq("visible")
      expect(r[:visible]).not_to include("<think>")
      expect(r[:visible]).not_to include("</think>")
    end

    it "handles </think> split across two chunks" do
      r = full_extract(parser, "<think>thought</thi", "nk>visible")
      expect(r[:thinking]).to eq("thought")
      expect(r[:visible]).to eq("visible")
    end

    it "handles both tags split across three chunks" do
      r = full_extract(parser, "<thi", "nk>some text</t", "hink>answer")
      expect(r[:thinking]).to eq("some text")
      expect(r[:visible]).to eq("answer")
    end

    it "handles <think> at the very end of a chunk (completely deferred)" do
      r = full_extract(parser, "prefix<think>", "thought</think>suffix")
      expect(r[:thinking]).to eq("thought")
      expect(r[:visible]).to eq("prefixsuffix")
    end

    it "handles </think> at the very end of a chunk" do
      r = full_extract(parser, "<think>thought</think>", "visible")
      expect(r[:thinking]).to eq("thought")
      expect(r[:visible]).to eq("visible")
    end

    it "never emits a partial opening tag in visible content during streaming" do
      # During streaming, the partial '<thi' is held — not emitted to visible
      r = parser.push("abc<thi")
      expect(r[:visible]).not_to include("<thi")
      expect(r[:visible]).not_to include("<think>")
      # When more data confirms it's not a tag, it eventually flushes through
      r2 = parser.push("x>rest")
      all = [r, r2, parser.flush].map { |v| v[:visible] }.join
      expect(all).to include("abc")
      expect(all).not_to include("<think>")
      expect(all).not_to include("</think>")
    end

    it "emits held prefix if it turns out not to be a tag" do
      # <thx is not <think>, so it should eventually flush as visible
      r = full_extract(parser, "a<thx>b")
      full = r[:visible]
      expect(full).to include("a")
    end
  end

  describe "multiple think blocks" do
    it "handles two sequential think blocks" do
      r = full_extract(parser, "<think>first</think>between<think>second</think>end")
      expect(r[:thinking]).to eq("firstsecond")
      expect(r[:visible]).to eq("betweenend")
    end
  end

  describe "real fixture content" do
    let(:oai_ns) { fixture_json("oai_ns.json") }
    let(:raw_content) { oai_ns.dig("choices", 0, "message", "content") }

    it "extracts think from oai_ns.json content without leaking tags" do
      r = full_extract(parser, raw_content)
      expect(r[:visible]).not_to include("<think>")
      expect(r[:visible]).not_to include("</think>")
      expect(r[:thinking]).not_to be_empty
      expect(r[:visible]).not_to be_empty
    end
  end
end
