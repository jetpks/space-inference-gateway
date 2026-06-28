# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module LocalInferenceProxy
  class OaiNormalizer
    def initialize(advertised_model:, supports_reasoning: true)
      @advertised_model   = advertised_model
      @supports_reasoning = supports_reasoning
    end

    # Normalize a non-stream OpenAI chat.completion hash.
    # Returns a conformant hash with <think> lifted to reasoning_content.
    def normalize(input)
      choices = (input["choices"] || []).map { |c| normalize_choice(c) }

      out = {
        "id" => input["id"],
        "object" => input["object"],
        "created" => input["created"],
        "model" => @advertised_model,
        "choices" => choices,
        "usage" => sanitize_usage(input["usage"]),
      }
      out["system_fingerprint"] = input["system_fingerprint"] if input.key?("system_fingerprint")
      out
    end

    # Feed raw SSE text from the upstream; returns array of normalized chunk hashes.
    # Diffusion_frame chunks are silently dropped.
    # Normal delta chunks are run through the streaming reasoning parser when supports_reasoning.
    def normalize_stream_chunks(sse_text)
      parser     = @supports_reasoning ? ReasoningParser.new : nil
      canonical  = nil
      created    = nil
      result     = []

      parse_sse_data(sse_text).each do |raw|
        next if raw == "[DONE]"

        data = JSON.parse(raw)
        next if data["type"] == "diffusion_frame"

        canonical ||= data["id"]
        created   ||= data["created"]

        result.concat(emit_chunks(data, canonical, created, parser))
      end

      # Flush any remaining buffered content before done
      if parser && canonical
        flush = parser.flush
        result.concat(flush_chunks(flush, canonical, created)) unless flush[:thinking].empty? && flush[:visible].empty?
      end

      result
    end

    # Returns the full SSE text (each chunk as "data: ...\n\n", ending with "data: [DONE]\n\n").
    def normalize_stream_to_sse(sse_text)
      chunks = normalize_stream_chunks(sse_text)
      lines  = chunks.map { |c| "data: #{JSON.generate(c)}\n\n" }
      lines << "data: [DONE]\n\n"
      lines.join
    end

    private

    def normalize_choice(choice)
      msg     = choice["message"] || {}
      content = msg["content"].to_s

      if @supports_reasoning
        parser   = ReasoningParser.new
        r        = parser.push(content)
        r2       = parser.flush
        thinking = r[:thinking] + r2[:thinking]
        visible  = r[:visible]  + r2[:visible]
      else
        thinking = ""
        visible  = content
      end

      message = {
        "role" => msg["role"],
        "content" => visible.empty? ? nil : visible,
        "refusal" => msg["refusal"],
      }
      message["reasoning_content"] = thinking unless thinking.empty?

      out = {
        "index" => choice["index"],
        "message" => message,
        "finish_reason" => choice["finish_reason"],
      }
      out["logprobs"] = choice["logprobs"] if choice.key?("logprobs")
      out
    end

    def sanitize_usage(usage)
      return {} unless usage.is_a?(Hash)

      {
        "prompt_tokens" => usage["prompt_tokens"].to_i,
        "completion_tokens" => usage["completion_tokens"].to_i,
        "total_tokens" => usage["total_tokens"].to_i,
      }
    end

    def parse_sse_data(text)
      text.lines.filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?("data:")

        stripped.sub(/\Adata:\s*/, "")
      end
    end

    def base_chunk(canonical_id, created)
      {
        "id" => canonical_id,
        "object" => "chat.completion.chunk",
        "created" => created,
        "model" => @advertised_model,
      }
    end

    def emit_chunks(data, canonical, created, parser)
      base = base_chunk(canonical, created)
      (data["choices"] || []).flat_map { |c| emit_choice(c, base, canonical, created, parser) }
    end

    def emit_choice(choice, base, canonical, created, parser)
      delta  = choice["delta"] || {}
      result = []

      if delta.key?("content")
        result.concat(emit_content_delta(choice, base, canonical, created, parser))
      elsif choice["finish_reason"]
        flush_into(result, parser, canonical, created, choice["index"])
        result << finish_chunk(base, choice)
      else
        result << base.merge("choices" => [{ "index" => choice["index"], "delta" => delta.slice("role") }])
      end

      result
    end

    def emit_content_delta(choice, base, canonical, created, parser)
      delta  = choice["delta"] || {}
      result = []

      if parser
        r = parser.push(delta["content"].to_s)
        result.concat(flush_chunks(r, canonical, created, choice["index"]))
      else
        result << base.merge("choices" => [{ "index" => choice["index"],
                                             "delta" => { "content" => delta["content"] }, }])
      end
      return result unless choice["finish_reason"]

      flush_into(result, parser, canonical, created, choice["index"])
      result << finish_chunk(base, choice)
      result
    end

    def flush_into(result, parser, canonical, created, index)
      return unless parser

      result.concat(flush_chunks(parser.flush, canonical, created, index))
    end

    def finish_chunk(base, choice)
      base.merge("choices" => [{ "index" => choice["index"], "delta" => {},
                                 "finish_reason" => choice["finish_reason"], }])
    end

    def flush_chunks(r, canonical, created, index = 0)
      result = []
      base   = base_chunk(canonical, created)

      unless r[:thinking].empty?
        result << base.merge("choices" => [{ "index" => index, "delta" => { "reasoning_content" => r[:thinking] } }])
      end

      unless r[:visible].empty?
        result << base.merge("choices" => [{ "index" => index, "delta" => { "content" => r[:visible] } }])
      end

      result
    end
  end
end
