# frozen_string_literal: true

LLAMACPP_FIXTURE_PATH = File.expand_path("../fixtures/llamacpp", __dir__)
SYNTHETIC_FIXTURE_PATH = File.expand_path("../fixtures/synthetic", __dir__)

def fixture_llamacpp(name)
  File.read(File.join(LLAMACPP_FIXTURE_PATH, name))
end

def fixture_llamacpp_json(name)
  JSON.parse(fixture_llamacpp(name))
end

def fixture_synthetic(name)
  File.read(File.join(SYNTHETIC_FIXTURE_PATH, name))
end

RSpec.describe SpaceInferenceGateway::AntNormalizer do
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
      schema_result = SpaceInferenceGateway::Schemas::ANT_MESSAGE.call(result)
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
      expect(SpaceInferenceGateway::Schemas::ANT_MESSAGE.call(result)).to be_success
    end
  end

  # ── AC-A1: Non-stream native thinking conformed (llama.cpp real fixture) ─
  describe "#normalize — AC-A1 native thinking non-stream" do
    let(:raw)    { fixture_llamacpp_json("ant_ns_real.json") }
    let(:result) { normalizer.normalize(raw) }

    it "validates against ANT_MESSAGE schema" do
      schema_result = SpaceInferenceGateway::Schemas::ANT_MESSAGE.call(result)
      expect(schema_result).to be_success, "schema errors: #{schema_result.errors.to_h.inspect}"
    end

    it "thinking block byte-equals upstream thinking" do
      upstream_thinking = raw["content"].find { |b| b["type"] == "thinking" }["thinking"]
      out_thinking      = result["content"].find { |b| b["type"] == "thinking" }
      expect(out_thinking["thinking"]).to eq(upstream_thinking)
    end

    it "text block byte-equals upstream text" do
      upstream_text = raw["content"].find { |b| b["type"] == "text" }["text"]
      out_text      = result["content"].find { |b| b["type"] == "text" }
      expect(out_text["text"]).to eq(upstream_text)
    end

    it "no content block carries signature or extra keys" do
      result["content"].each do |block|
        expect(block.keys).to match_array(
          block["type"] == "thinking" ? %w[type thinking] : %w[type text],
        )
      end
    end

    it "model is the advertised alias, not a gguf path" do
      expect(result["model"]).to eq("test-model")
      expect(result["model"]).not_to include("/")
    end
  end

  # ── g_ant_ns: Non-stream tool_use passthrough (AC4/AC5) ──────────────────
  describe "#normalize — g_ant_ns tool_use passthrough" do
    let(:raw)    { fixture_llamacpp_json("ant_ns_tooluse_real.json") }
    let(:result) { normalizer.normalize(raw) }

    it "preserves tool_use content block" do
      tu = result["content"].find { |b| b["type"] == "tool_use" }
      expect(tu).not_to be_nil
      expect(tu["id"]).to be_a(String)
      expect(tu["name"]).to eq("get_weather")
      expect(tu["input"]).to eq("city" => "Denver")
    end

    it "preserves stop_reason: tool_use" do
      expect(result["stop_reason"]).to eq("tool_use")
    end

    it "validates ANT_MESSAGE schema" do
      r = SpaceInferenceGateway::Schemas::ANT_MESSAGE.call(result)
      expect(r).to be_success, r.errors.to_h.inspect
    end
  end

  # ── g_ant_s: Stream tool_use passthrough (AC3) ────────────────────────────
  describe "#normalize_stream_events — g_ant_s tool_use stream passthrough" do
    let(:raw_sse) { fixture_llamacpp("ant_s_tooluse_real.txt") }
    let(:events)  { normalizer.normalize_stream_events(raw_sse) }

    let(:tool_use_start) do
      events.find { |e| e[:data]["type"] == "content_block_start" && e[:data].dig("content_block", "type") == "tool_use" }
    end

    it "emits content_block_start with type tool_use and name get_weather" do
      expect(tool_use_start).not_to be_nil
      expect(tool_use_start[:data].dig("content_block", "name")).to eq("get_weather")
    end

    it "emits input_json_delta events whose concatenated partial_json parses to city Denver" do
      idx    = tool_use_start[:data]["index"]
      deltas = events.select do |e|
        e[:data]["type"] == "content_block_delta" &&
          e[:data]["index"] == idx &&
          e[:data].dig("delta", "type") == "input_json_delta"
      end
      json = deltas.map { |e| e[:data].dig("delta", "partial_json") }.join
      expect(JSON.parse(json)).to eq("city" => "Denver")
    end

    it "emits content_block_stop for the tool_use block" do
      idx = tool_use_start[:data]["index"]
      expect(events.any? { |e| e[:data]["type"] == "content_block_stop" && e[:data]["index"] == idx }).to be(true)
    end

    it "emitted content_block_start indexes are distinct" do
      idxs = events.select { |e| e[:data]["type"] == "content_block_start" }.map { |e| e[:data]["index"] }
      expect(idxs.uniq).to eq(idxs)
    end
  end

  # ── AC4: Stream inline-<think> + tool_use index collision (synthetic fixture) ──
  describe "#normalize_stream_events — g_idx_synth inline think + tool_use indexes" do
    let(:raw_sse) { fixture_synthetic("ant_s_inline_think_tooluse.txt") }
    let(:events)  { normalizer.normalize_stream_events(raw_sse) }

    let(:starts) { events.select { |e| e[:data]["type"] == "content_block_start" } }
    let(:stops)  { events.select { |e| e[:data]["type"] == "content_block_stop" } }

    let(:tool_use_start) do
      starts.find { |e| e[:data].dig("content_block", "type") == "tool_use" }
    end

    it "emits pairwise-distinct content_block_start indexes" do
      idxs = starts.map { |e| e[:data]["index"] }
      expect(idxs.uniq).to eq(idxs)
    end

    it "emits thinking, text, and tool_use blocks" do
      types = starts.map { |e| e[:data].dig("content_block", "type") }
      expect(types.sort).to eq(%w[text thinking tool_use])
    end

    it "concatenated visible text is exactly the post-think text" do
      text_deltas = events.select { |e| e[:data].dig("delta", "type") == "text_delta" }
      visible_text = text_deltas.map { |e| e[:data].dig("delta", "text") }.join
      expect(visible_text).to eq("visible answer")
    end

    it "tool_use deltas and stop carry the (re)mapped start index" do
      idx = tool_use_start[:data]["index"]
      deltas = events.select do |e|
        e[:data]["type"] == "content_block_delta" &&
          e[:data]["index"] == idx &&
          e[:data].dig("delta", "type") == "input_json_delta"
      end
      json = deltas.map { |e| e[:data].dig("delta", "partial_json") }.join
      expect(JSON.parse(json)).to eq("city" => "Denver")
      expect(stops.any? { |e| e[:data]["index"] == idx }).to be(true)
    end

    it "every emitted stop index matches an emitted start index" do
      expect(stops.map { |e| e[:data]["index"] }.sort).to eq(starts.map { |e| e[:data]["index"] }.sort)
    end
  end

  # ── AC-A2: Stream native thinking relayed losslessly (llama.cpp real fixture)
  describe "#normalize_stream_events — AC-A2 native thinking stream" do
    let(:raw_sse) { fixture_llamacpp("ant_s_real.txt") }

    let(:upstream_thinking) do
      raw_sse.lines.each_with_object(+"") do |l, buf|
        next unless l.start_with?("data:")

        d = JSON.parse(l.sub(/\Adata:\s*/, ""))
        buf << d.dig("delta", "thinking").to_s if d.dig("delta", "type") == "thinking_delta"
      rescue JSON::ParserError
        nil
      end
    end

    let(:upstream_text) do
      raw_sse.lines.each_with_object(+"") do |l, buf|
        next unless l.start_with?("data:")

        d = JSON.parse(l.sub(/\Adata:\s*/, ""))
        buf << d.dig("delta", "text").to_s if d.dig("delta", "type") == "text_delta"
      rescue JSON::ParserError
        nil
      end
    end

    let(:events) { normalizer.normalize_stream_events(raw_sse) }

    it "concatenated thinking_delta byte-equals upstream thinking" do
      out = events.select { |e| e[:data].dig("delta", "type") == "thinking_delta" }
                  .map { |e| e[:data].dig("delta", "thinking").to_s }
                  .join
      expect(out).to eq(upstream_thinking)
    end

    it "concatenated text_delta byte-equals upstream text" do
      out = events.select { |e| e[:data].dig("delta", "type") == "text_delta" }
                  .map { |e| e[:data].dig("delta", "text").to_s }
                  .join
      expect(out).to eq(upstream_text)
    end

    it "message_start model is the advertised alias" do
      msg_start = events.find { |e| e[:event] == "message_start" }
      expect(msg_start[:data].dig("message", "model")).to eq("test-model")
      expect(msg_start[:data].dig("message", "model")).not_to include("/")
    end

    it "no emitted thinking content_block carries signature" do
      thinking_starts = events.select do |e|
        e[:event] == "content_block_start" &&
          e[:data].dig("content_block", "type") == "thinking"
      end
      expect(thinking_starts).not_to be_empty
      thinking_starts.each do |e|
        expect(e[:data]["content_block"].keys).not_to include("signature")
      end
    end

    it "includes content_block_start for both thinking and text" do
      types = events.select { |e| e[:event] == "content_block_start" }
                    .map { |e| e[:data].dig("content_block", "type") }
      expect(types).to include("thinking")
      expect(types).to include("text")
    end

    it "ends with message_stop" do
      expect(events.last[:event]).to eq("message_stop")
    end
  end
end
