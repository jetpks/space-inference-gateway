# frozen_string_literal: true

LLAMACPP_FIXTURE_PATH = File.expand_path("../fixtures/llamacpp", __dir__)

def llamacpp_fixture(name)
  File.read(File.join(LLAMACPP_FIXTURE_PATH, name))
end

def llamacpp_fixture_json(name)
  JSON.parse(llamacpp_fixture(name))
end

RSpec.describe SpaceInferenceGateway::OaiNormalizer do
  subject(:normalizer) { described_class.new(advertised_model: "test-model") }

  let(:oai_ns_fixture) { fixture_json("oai_ns.json") }
  let(:oai_s_fixture)  { fixture("oai_s.txt") }

  # ── AC1: Reasoning lift, non-stream ──────────────────────────────────────
  describe "#normalize — AC1" do
    let(:result) { normalizer.normalize(oai_ns_fixture) }

    it "removes <think> and </think> from content" do
      content = result.dig("choices", 0, "message", "content")
      expect(content).not_to include("<think>")
      expect(content).not_to include("</think>")
    end

    it "places think text in reasoning_content" do
      rc = result.dig("choices", 0, "message", "reasoning_content")
      expect(rc).to be_a(String)
      expect(rc).not_to be_empty
    end

    it "reasoning_content contains actual think text" do
      rc = result.dig("choices", 0, "message", "reasoning_content")
      expect(rc).to include("Method")
    end

    it "visible content is non-empty" do
      content = result.dig("choices", 0, "message", "content")
      expect(content).not_to be_nil
      expect(content).not_to be_empty
    end
  end

  # ── AC2: Field conformance, non-stream ───────────────────────────────────
  describe "#normalize — AC2" do
    let(:result) { normalizer.normalize(oai_ns_fixture) }

    it "advertises the configured model name, not the full path" do
      expect(result["model"]).to eq("test-model")
      expect(result["model"]).not_to include("/")
    end

    it "validates against OAI_COMPLETION schema" do
      schema_result = SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(result)
      expect(schema_result).to be_success
    end

    it "contains no diffusion_frame keys at top level" do
      SpaceInferenceGateway::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
        expect(result.keys).not_to include(key),
                                   "expected result not to contain key #{key.inspect}"
      end
    end

    it "schema to_h strips any banned keys" do
      payload = result.merge("type" => "diffusion_frame", "block" => 0, "step" => 0, "total" => 48, "text" => "noise")
      stripped = SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(payload).to_h
      SpaceInferenceGateway::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
        expect(stripped.keys).not_to include(key)
      end
    end
  end

  # ── AC3: Streaming diffusion reconstruction (OpenAI) ─────────────────────
  describe "#normalize_stream_chunks — AC3" do
    let(:chunks) { normalizer.normalize_stream_chunks(oai_s_fixture) }

    it "(a) all chunks validate strict chat.completion.chunk — no diffusion extras" do
      chunks.each do |chunk|
        SpaceInferenceGateway::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
          expect(chunk.keys).not_to include(key),
                                    "chunk contains banned key #{key.inspect}: #{chunk.inspect}"
        end

        schema_result = SpaceInferenceGateway::Schemas::OAI_CHUNK.call(chunk)
        expect(schema_result).to be_success,
                                 "chunk failed schema validation: #{schema_result.errors.to_h.inspect}\nchunk=#{chunk.inspect}"
      end
    end

    it "(b) concatenated delta.content EQUALS final denoised visible answer with <think> removed" do
      content_text = chunks.filter_map { |c| c.dig("choices", 0, "delta", "content") }.join
      # Exact equality against the visible text following </think> in oai_s.txt chunks
      # (id chatcmpl-427f8b35d748, the two trailing autoregressive deltas)
      expect(content_text).to eq("Thought: I will greet the user.\n\nHi!")
    end

    it "(c) think text is delivered via delta.reasoning_content" do
      reasoning_chunks = chunks.select { |c| c.dig("choices", 0, "delta", "reasoning_content") }
      expect(reasoning_chunks).not_to be_empty
      thinking_text = reasoning_chunks.map { |c| c.dig("choices", 0, "delta", "reasoning_content") }.join
      expect(thinking_text).not_to be_empty
    end

    it "(d) one consistent id across all chunks" do
      ids = chunks.map { |c| c["id"] }.uniq
      expect(ids.length).to eq(1)
    end

    it "(d) advertised model across all chunks" do
      models = chunks.map { |c| c["model"] }.uniq
      expect(models).to eq(["test-model"])
    end

    it "(d) model is advertised name, not full path" do
      chunks.each do |c|
        expect(c["model"]).not_to include("/")
      end
    end
  end

  describe "#normalize_stream_to_sse — AC3(e)" do
    let(:sse_output) { normalizer.normalize_stream_to_sse(oai_s_fixture) }

    it "(e) stream ends with data: [DONE]" do
      expect(sse_output.strip).to end_with("data: [DONE]")
    end

    it "each data: line parses as valid JSON (except [DONE])" do
      sse_output.lines.each do |line|
        next unless line.strip.start_with?("data:")

        raw = line.strip.sub(/\Adata:\s*/, "")
        next if raw == "[DONE]"

        expect { JSON.parse(raw) }.not_to raise_error
      end
    end
  end

  # ── AC6: Normal (non-diffusion) autoregressive stream ────────────────────
  describe "#normalize_stream_chunks — AC6 autoregressive passthrough" do
    let(:ar_stream) { fixture("oai_ar_s.txt") }
    let(:chunks)    { normalizer.normalize_stream_chunks(ar_stream) }

    it "all chunks pass strict schema" do
      chunks.each do |chunk|
        result = SpaceInferenceGateway::Schemas::OAI_CHUNK.call(chunk)
        expect(result).to be_success, "failed: #{result.errors.to_h.inspect}"
      end
    end

    it "no banned diffusion keys present" do
      chunks.each do |chunk|
        SpaceInferenceGateway::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
          expect(chunk.keys).not_to include(key)
        end
      end
    end

    it "uses advertised model" do
      expect(chunks.map { |c| c["model"] }.uniq).to eq(["test-model"])
    end
  end

  # ── AC6: Non-reasoning response passthrough ───────────────────────────────
  describe "#normalize — AC6 non-reasoning passthrough" do
    let(:no_chain) { fixture_json("oai_nochain.json") }
    let(:result)   { normalizer.normalize(no_chain) }

    it "content passes through unchanged" do
      original = no_chain.dig("choices", 0, "message", "content")
      expect(result.dig("choices", 0, "message", "content")).to eq(original)
    end

    it "no reasoning_content key when no think tags" do
      expect(result.dig("choices", 0, "message")).not_to have_key("reasoning_content")
    end

    it "validates against schema" do
      expect(SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(result)).to be_success
    end
  end

  # ── AC-O1: Non-stream real llama.cpp fixture — upstream reasoning_content consumed ─
  describe "#normalize — AC-O1 real llama.cpp non-stream" do
    let(:upstream) { llamacpp_fixture_json("oai_ns_complete_real.json") }
    let(:result)   { normalizer.normalize(upstream) }

    it "validates OAI_COMPLETION schema" do
      expect(SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(result)).to be_success
    end

    it "reasoning_content present and byte-equal to upstream" do
      expected = upstream.dig("choices", 0, "message", "reasoning_content")
      expect(result.dig("choices", 0, "message", "reasoning_content")).to eq(expected)
    end

    it "content byte-equal to upstream content" do
      expected = upstream.dig("choices", 0, "message", "content")
      expect(result.dig("choices", 0, "message", "content")).to eq(expected)
    end

    it "model is advertised alias, not gguf path" do
      expect(result["model"]).to eq("test-model")
      expect(result["model"]).not_to start_with("/")
    end

    it "no top-level timings key" do
      expect(result.keys).not_to include("timings")
    end

    it "usage has exactly prompt_tokens/completion_tokens/total_tokens" do
      expect(result["usage"].keys.sort).to eq(%w[completion_tokens prompt_tokens total_tokens])
    end
  end

  # ── AC-O2: Stream real llama.cpp fixture — reasoning_content relayed losslessly ─
  describe "#normalize_stream_chunks — AC-O2 real llama.cpp stream" do
    let(:fixture_text) { llamacpp_fixture("oai_s_complete_real.txt") }
    let(:chunks)       { normalizer.normalize_stream_chunks(fixture_text) }

    let(:upstream_reasoning) do
      fixture_text.lines.filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?("data:")

        raw = stripped.sub(/\Adata:\s*/, "")
        next if raw == "[DONE]"

        JSON.parse(raw).dig("choices", 0, "delta", "reasoning_content")
      end.join
    end

    let(:upstream_content) do
      fixture_text.lines.filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?("data:")

        raw = stripped.sub(/\Adata:\s*/, "")
        next if raw == "[DONE]"

        JSON.parse(raw).dig("choices", 0, "delta", "content")
      end.join
    end

    it "every emitted chunk validates OAI_CHUNK" do
      chunks.each do |chunk|
        r = SpaceInferenceGateway::Schemas::OAI_CHUNK.call(chunk)
        expect(r).to be_success,
                     "chunk failed schema: #{r.errors.to_h.inspect}\nchunk=#{chunk.inspect}"
      end
    end

    it "concatenated delta.reasoning_content equals upstream" do
      output_rc = chunks.filter_map { |c| c.dig("choices", 0, "delta", "reasoning_content") }.join
      expect(output_rc).to eq(upstream_reasoning)
    end

    it "concatenated delta.content equals upstream" do
      output_content = chunks.filter_map { |c| c.dig("choices", 0, "delta", "content") }.join
      expect(output_content).to eq(upstream_content)
    end

    it "no chunk carries timings" do
      chunks.each { |c| expect(c.keys).not_to include("timings") }
    end

    it "no chunk model is a gguf path" do
      chunks.each { |c| expect(c["model"]).not_to start_with("/") }
    end

    it "SSE output ends with data: [DONE]" do
      sse = normalizer.normalize_stream_to_sse(fixture_text)
      expect(sse.strip).to end_with("data: [DONE]")
    end
  end

  # ── AC-O3: Inline <think> fallback intact ─────────────────────────────────
  # The existing AC1/AC3 describe blocks above exercise this path:
  # oai_ns.json has inline <think>…</think> in content, no upstream reasoning_content key.
  # oai_s.txt has inline <think>…</think> in delta.content.
  # Both paths continue to lift think text into reasoning_content correctly.

  # ── g_oai_ns: Non-stream tool_calls passthrough (AC1/AC5) ─────────────────
  describe "#normalize — g_oai_ns tool_calls passthrough" do
    let(:upstream) { llamacpp_fixture_json("oai_ns_toolcall_real.json") }
    let(:result)   { normalizer.normalize(upstream) }

    it "preserves tool_calls array verbatim" do
      tc = result.dig("choices", 0, "message", "tool_calls")
      expect(tc).to be_an(Array)
      expect(tc.first["id"]).to be_a(String)
      expect(tc.first.dig("function", "name")).to eq("get_weather")
      expect(JSON.parse(tc.first.dig("function", "arguments"))).to eq("city" => "Denver")
    end

    it "preserves finish_reason: tool_calls" do
      expect(result.dig("choices", 0, "finish_reason")).to eq("tool_calls")
    end

    it "validates OAI_COMPLETION schema" do
      r = SpaceInferenceGateway::Schemas::OAI_COMPLETION.call(result)
      expect(r).to be_success, r.errors.to_h.inspect
    end
  end

  # ── g_oai_s: Stream tool_call deltas passthrough (AC2/AC5) ────────────────
  describe "#normalize_stream_chunks — g_oai_s tool_call stream passthrough" do
    let(:fixture_text) { llamacpp_fixture("oai_s_toolcall_real.txt") }
    let(:chunks)       { normalizer.normalize_stream_chunks(fixture_text) }

    let(:tool_call_deltas) do
      chunks.flat_map { |c| c["choices"] }.filter_map { |ch| ch["delta"]["tool_calls"] }.flatten
    end

    it "emits tool_call deltas" do
      expect(tool_call_deltas).not_to be_empty
    end

    it "first tool_call delta carries function.name get_weather" do
      expect(tool_call_deltas.first.dig("function", "name")).to eq("get_weather")
    end

    it "concatenated function.arguments parse to city Denver" do
      args = tool_call_deltas.filter_map { |t| t.dig("function", "arguments") }.join
      expect(JSON.parse(args)).to eq("city" => "Denver")
    end

    it "emits no empty-delta chunks for tool_calls (no loss)" do
      bad = chunks.flat_map { |c| c["choices"] }.select { |ch| ch["delta"] == {} && ch["finish_reason"].nil? }
      expect(bad).to be_empty
    end

    it "all chunks validate OAI_CHUNK schema" do
      chunks.each do |chunk|
        r = SpaceInferenceGateway::Schemas::OAI_CHUNK.call(chunk)
        expect(r).to be_success, "chunk failed schema: #{r.errors.to_h.inspect}\nchunk=#{chunk.inspect}"
      end
    end
  end
end
