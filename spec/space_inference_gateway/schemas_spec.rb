# frozen_string_literal: true

RSpec.describe SpaceInferenceGateway::Schemas do
  describe "OAI_COMPLETION" do
    subject(:schema) { described_class::OAI_COMPLETION }

    let(:valid_payload) do
      {
        "id" => "chatcmpl-abc",
        "object" => "chat.completion",
        "created" => 1_700_000_000,
        "model" => "local-inference",
        "choices" => [{
          "index" => 0,
          "message" => { "role" => "assistant", "content" => "hello" },
          "finish_reason" => "stop",
        }],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 },
      }
    end

    it "accepts a valid normalized completion" do
      expect(schema.call(valid_payload)).to be_success
    end

    it "AC2 — genuinely rejects payload carrying diffusion_frame extras at top level" do
      payload = valid_payload.merge(
        "type" => "diffusion_frame", "block" => 0, "step" => 1, "total" => 48, "text" => "noise",
      )
      expect(schema.call(payload)).not_to be_success
    end

    it "rejects missing required fields" do
      expect(schema.call(valid_payload.except("id"))).not_to be_success
    end

    it "accepts message with tool_calls array" do
      payload = valid_payload.merge("choices" => [{
                                      "index" => 0,
                                      "message" => {
                                        "role" => "assistant",
                                        "content" => nil,
                                        "tool_calls" => [{
                                          "id" => "call_abc",
                                          "type" => "function",
                                          "function" => { "name" => "get_weather", "arguments" => '{"city":"Denver"}' },
                                        }],
                                      },
                                      "finish_reason" => "tool_calls",
                                    }])
      expect(schema.call(payload)).to be_success
    end
  end

  describe "OAI_CHUNK" do
    subject(:schema) { described_class::OAI_CHUNK }

    let(:valid_chunk) do
      {
        "id" => "chatcmpl-abc",
        "object" => "chat.completion.chunk",
        "created" => 1_700_000_000,
        "model" => "local-inference",
        "choices" => [{ "index" => 0, "delta" => { "content" => "hi" } }],
      }
    end

    it "accepts a valid chunk" do
      expect(schema.call(valid_chunk)).to be_success
    end

    it "rejects wrong object type" do
      expect(schema.call(valid_chunk.merge("object" => "chat.completion"))).not_to be_success
    end

    it "AC2 — genuinely rejects payload with diffusion_frame extras at top level" do
      payload = valid_chunk.merge(
        "type" => "diffusion_frame", "block" => 0, "step" => 0, "total" => 48, "text" => "noise",
      )
      expect(schema.call(payload)).not_to be_success
    end

    it "AC2 — rejects diffusion extras inside delta" do
      payload = valid_chunk.merge("choices" => [{
                                    "index" => 0,
                                    "delta" => { "content" => "hi", "unknown_extra" => "bad" },
                                  }])
      expect(schema.call(payload)).not_to be_success
    end

    it "accepts delta with tool_calls array" do
      payload = valid_chunk.merge("choices" => [{
                                    "index" => 0,
                                    "delta" => {
                                      "tool_calls" => [{ "index" => 0, "id" => "call_abc", "type" => "function",
                                                         "function" => { "name" => "get_weather", "arguments" => "{" }, }],
                                    },
                                  }])
      expect(schema.call(payload)).to be_success
    end

    it "accepts incremental tool_calls delta with only index and arguments" do
      payload = valid_chunk.merge("choices" => [{
                                    "index" => 0,
                                    "delta" => { "tool_calls" => [{ "index" => 0, "function" => { "arguments" => "more" } }] },
                                  }])
      expect(schema.call(payload)).to be_success
    end
  end

  describe "ANT_MESSAGE" do
    subject(:schema) { described_class::ANT_MESSAGE }

    let(:valid_payload) do
      {
        "id" => "msg_abc",
        "type" => "message",
        "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "hello" }],
        "model" => "local-inference",
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
      }
    end

    it "accepts a valid normalized message" do
      expect(schema.call(valid_payload)).to be_success
    end

    it "accepts thinking + text blocks" do
      payload = valid_payload.merge("content" => [
                                      { "type" => "thinking", "thinking" => "internal" },
                                      { "type" => "text", "text" => "visible" },
                                    ])
      expect(schema.call(payload)).to be_success
    end

    it "AC2 — genuinely rejects payload with unexpected top-level keys" do
      payload = valid_payload.merge("unexpected_key" => "bad")
      expect(schema.call(payload)).not_to be_success
    end

    it "accepts tool_use content block" do
      payload = valid_payload.merge(
        "content" => [{ "type" => "tool_use", "id" => "tu_abc", "name" => "get_weather",
                        "input" => { "city" => "Denver" }, }],
        "stop_reason" => "tool_use",
      )
      expect(schema.call(payload)).to be_success
    end
  end
end
