# frozen_string_literal: true

RSpec.describe LocalInferenceProxy::OaiNormalizer do
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
      schema_result = LocalInferenceProxy::Schemas::OAI_COMPLETION.call(result)
      expect(schema_result).to be_success
    end

    it "contains no diffusion_frame keys at top level" do
      LocalInferenceProxy::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
        expect(result.keys).not_to include(key),
                                   "expected result not to contain key #{key.inspect}"
      end
    end

    it "schema to_h strips any banned keys" do
      payload = result.merge("type" => "diffusion_frame", "block" => 0, "step" => 0, "total" => 48, "text" => "noise")
      stripped = LocalInferenceProxy::Schemas::OAI_COMPLETION.call(payload).to_h
      LocalInferenceProxy::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
        expect(stripped.keys).not_to include(key)
      end
    end
  end

  # ── AC3: Streaming diffusion reconstruction (OpenAI) ─────────────────────
  describe "#normalize_stream_chunks — AC3" do
    let(:chunks) { normalizer.normalize_stream_chunks(oai_s_fixture) }

    it "(a) all chunks validate strict chat.completion.chunk — no diffusion extras" do
      chunks.each do |chunk|
        LocalInferenceProxy::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
          expect(chunk.keys).not_to include(key),
                                    "chunk contains banned key #{key.inspect}: #{chunk.inspect}"
        end

        schema_result = LocalInferenceProxy::Schemas::OAI_CHUNK.call(chunk)
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
        result = LocalInferenceProxy::Schemas::OAI_CHUNK.call(chunk)
        expect(result).to be_success, "failed: #{result.errors.to_h.inspect}"
      end
    end

    it "no banned diffusion keys present" do
      chunks.each do |chunk|
        LocalInferenceProxy::Schemas::DIFFUSION_BANNED_KEYS.each do |key|
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
      expect(LocalInferenceProxy::Schemas::OAI_COMPLETION.call(result)).to be_success
    end
  end
end
