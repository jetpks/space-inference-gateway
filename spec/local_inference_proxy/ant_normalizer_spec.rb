# frozen_string_literal: true

RSpec.describe LocalInferenceProxy::AntNormalizer do
  subject(:normalizer) { described_class.new(advertised_model: "test-model") }

  let(:ant_ns_fixture) { fixture_json("ant_ns.json") }
  let(:ant_s_fixture)  { fixture("ant_s.txt") }

  # ── AC1: Reasoning lift, non-stream (Anthropic) ──────────────────────────
  describe "#normalize — AC1" do
    let(:result) { normalizer.normalize(ant_ns_fixture) }

    it "produces a thinking content block" do
      types = result["content"].map { |b| b["type"] }
      expect(types).to include("thinking")
    end

    it "produces a text content block" do
      types = result["content"].map { |b| b["type"] }
      expect(types).to include("text")
    end

    it "thinking block contains the thought text" do
      thinking_block = result["content"].find { |b| b["type"] == "thinking" }
      expect(thinking_block["thinking"]).not_to be_empty
    end

    it "text block contains no <think> tags" do
      text_block = result["content"].find { |b| b["type"] == "text" }
      expect(text_block["text"]).not_to include("<think>")
      expect(text_block["text"]).not_to include("</think>")
    end

    it "text block is non-empty" do
      text_block = result["content"].find { |b| b["type"] == "text" }
      expect(text_block["text"]).not_to be_empty
    end
  end

  # ── AC2: Field conformance (Anthropic) ───────────────────────────────────
  describe "#normalize — AC2" do
    let(:result) { normalizer.normalize(ant_ns_fixture) }

    it "advertises the configured model name" do
      expect(result["model"]).to eq("test-model")
      expect(result["model"]).not_to include("/")
    end

    it "validates against ANT_MESSAGE schema" do
      schema_result = LocalInferenceProxy::Schemas::ANT_MESSAGE.call(result)
      expect(schema_result).to be_success,
                               "schema errors: #{schema_result.errors.to_h.inspect}"
    end

    it "contains only expected top-level keys" do
      allowed = %w[id type role content model stop_reason stop_sequence usage]
      expect(result.keys).to match_array(allowed)
    end
  end

  # ── AC4: Streaming (Anthropic) ────────────────────────────────────────────
  describe "#normalize_stream_events — AC4" do
    let(:events) { normalizer.normalize_stream_events(ant_s_fixture) }

    it "begins with message_start" do
      expect(events.first[:event]).to eq("message_start")
    end

    it "includes content_block_start for thinking" do
      thinking_starts = events.select do |e|
        e[:event] == "content_block_start" &&
          e[:data].dig("content_block", "type") == "thinking"
      end
      expect(thinking_starts).not_to be_empty
    end

    it "includes content_block_start for text" do
      text_starts = events.select do |e|
        e[:event] == "content_block_start" &&
          e[:data].dig("content_block", "type") == "text"
      end
      expect(text_starts).not_to be_empty
    end

    it "thinking_delta contains think text without inline tags" do
      thinking_deltas = events.select do |e|
        e[:event] == "content_block_delta" &&
          e[:data].dig("delta", "type") == "thinking_delta"
      end
      thinking_text = thinking_deltas.map { |e| e[:data].dig("delta", "thinking") }.join
      expect(thinking_text).not_to be_empty
      expect(thinking_text).not_to include("<think>")
      expect(thinking_text).not_to include("</think>")
    end

    it "text_delta contains visible text without inline tags" do
      text_deltas = events.select do |e|
        e[:event] == "content_block_delta" &&
          e[:data].dig("delta", "type") == "text_delta"
      end
      visible_text = text_deltas.map { |e| e[:data].dig("delta", "text") }.join
      expect(visible_text).not_to be_empty
      expect(visible_text).not_to include("<think>")
      expect(visible_text).not_to include("</think>")
    end

    it "includes message_delta" do
      expect(events.any? { |e| e[:event] == "message_delta" }).to be(true)
    end

    it "ends with message_stop" do
      expect(events.last[:event]).to eq("message_stop")
    end

    it "advertises configured model in message_start" do
      msg_start = events.find { |e| e[:event] == "message_start" }
      expect(msg_start[:data].dig("message", "model")).to eq("test-model")
    end

    it "sequence: message_start → block events → message_delta → message_stop" do
      event_names = events.map { |e| e[:event] }
      expect(event_names.first).to eq("message_start")
      expect(event_names.last).to eq("message_stop")
      # message_delta comes before message_stop
      delta_idx = event_names.rindex("message_delta")
      stop_idx  = event_names.rindex("message_stop")
      expect(delta_idx).to be < stop_idx
    end
  end

  describe "#normalize_stream_to_sse — AC4 SSE output" do
    let(:sse_output) { normalizer.normalize_stream_to_sse(ant_s_fixture) }

    it "produces valid event:data pairs" do
      events = sse_output.split("\n\n").reject(&:empty?)
      events.each do |block|
        lines = block.lines.map(&:strip)
        expect(lines.any? { |l| l.start_with?("event:") }).to be(true)
        expect(lines.any? { |l| l.start_with?("data:") }).to be(true)
      end
    end

    it "all data payloads parse as valid JSON" do
      sse_output.lines.each do |line|
        next unless line.strip.start_with?("data:")

        raw = line.strip.sub(/\Adata:\s*/, "")
        expect { JSON.parse(raw) }.not_to raise_error
      end
    end
  end

  # ── AC6: Non-reasoning Anthropic passthrough ─────────────────────────────
  describe "#normalize — AC6 non-reasoning passthrough" do
    let(:no_chain) { fixture_json("ant_nochain.json") }
    let(:result)   { normalizer.normalize(no_chain) }

    it "content passes through as text block" do
      original = no_chain.dig("content", 0, "text")
      text_block = result["content"].find { |b| b["type"] == "text" }
      expect(text_block["text"]).to eq(original)
    end

    it "no thinking block when no think tags" do
      types = result["content"].map { |b| b["type"] }
      expect(types).not_to include("thinking")
    end

    it "validates against schema" do
      expect(LocalInferenceProxy::Schemas::ANT_MESSAGE.call(result)).to be_success
    end
  end
end
