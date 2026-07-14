# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module SpaceInferenceGateway
  class OaiNormalizer # rubocop:disable Metrics/ClassLength
    # reasoning_field: the upstream key that carries the reasoning text.
    # mlx uses "reasoning"; a true-OAI upstream (llama-server) uses "reasoning_content".
    def initialize(advertised_model:, supports_reasoning: true, reasoning_field: "reasoning")
      @advertised_model   = advertised_model
      @supports_reasoning = supports_reasoning
      @reasoning_field    = reasoning_field
    end

    # Normalize a non-stream OpenAI chat.completion hash.
    # Returns a conformant hash with <think> lifted to reasoning_content.
    def normalize(input)
      choices = (input["choices"] || []).map { |c| normalize_choice(c) }

      {
        "id" => input["id"],
        "object" => input["object"],
        "created" => input["created"],
        "model" => @advertised_model,
        "choices" => choices,
        "usage" => sanitize_usage(input["usage"]),
      }
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

    # Incremental streaming entry — pulls raw SSE bytes from upstream_body chunk-by-chunk
    # and yields normalized SSE strings as they become available.
    # Byte-identical to normalize_stream_to_sse when output is concatenated.
    def stream_to_sse(upstream_body)
      parser    = @supports_reasoning ? ReasoningParser.new : nil
      canonical = nil
      created   = nil
      buf       = +""

      upstream_body.each do |raw_chunk|
        buf << raw_chunk

        while (idx = buf.index("\n\n"))
          buf.slice!(0, idx + 2).each_line do |line|
            canonical, created, chunks = normalize_sse_line(line, canonical, created, parser)
            chunks.each { |chunk| yield "data: #{JSON.generate(chunk)}\n\n" }
          end
        end
      end

      if parser && canonical
        flush = parser.flush
        unless flush[:thinking].empty? && flush[:visible].empty?
          flush_chunks(flush, canonical, created).each do |chunk|
            yield "data: #{JSON.generate(chunk)}\n\n"
          end
        end
      end

      yield "data: [DONE]\n\n"
    end

    private

    def normalize_choice(choice)
      msg     = choice["message"] || {}
      content = msg["content"].to_s

      if @supports_reasoning
        if msg.key?(@reasoning_field)
          thinking = msg[@reasoning_field].to_s
          visible  = content
        else
          parser   = ReasoningParser.new
          r        = parser.push(content)
          r2       = parser.flush
          thinking = r[:thinking] + r2[:thinking]
          visible  = r[:visible]  + r2[:visible]
        end
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
      message["tool_calls"] = msg["tool_calls"] if msg.key?("tool_calls")

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

    def normalize_sse_line(line, canonical, created, parser)
      stripped = line.strip
      return [canonical, created, []] unless stripped.start_with?("data:")

      raw = stripped.sub(/\Adata:\s*/, "")
      return [canonical, created, []] if raw == "[DONE]"

      data = JSON.parse(raw)
      return [canonical, created, []] if data["type"] == "diffusion_frame"

      canonical ||= data["id"]
      created   ||= data["created"]
      [canonical, created, emit_chunks(data, canonical, created, parser)]
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

      if delta.key?(@reasoning_field)
        flush_into(result, parser, canonical, created, choice["index"])
        result.concat(emit_reasoning_delta(choice, base))
      elsif delta.key?("content")
        result.concat(emit_content_delta(choice, base, canonical, created, parser))
      elsif choice["finish_reason"]
        flush_into(result, parser, canonical, created, choice["index"])
        result << finish_chunk(base, choice)
      else
        result << base.merge("choices" => [{ "index" => choice["index"], "delta" => delta.slice("role") }])
      end

      # mlx emits tool_calls in their own chunk (alongside content or
      # finish_reason); pass them through verbatim so the client can execute.
      if delta.key?("tool_calls")
        flush_into(result, parser, canonical, created, choice["index"])
        result << base.merge("choices" => [{ "index" => choice["index"],
                                             "delta" => { "tool_calls" => delta["tool_calls"] }, }])
      end
      result
    end

    def emit_reasoning_delta(choice, base)
      delta = choice["delta"] || {}
      rc    = delta[@reasoning_field]
      result = [base.merge("choices" => [{ "index" => choice["index"], "delta" => { "reasoning_content" => rc } }])]
      result << finish_chunk(base, choice) if choice["finish_reason"]
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
      chunk = base.merge("choices" => [{ "index" => choice["index"], "delta" => {},
                                         "finish_reason" => choice["finish_reason"], }])
      # Carry tool_calls onto the finish chunk when present (some clients read
      # them from the finish chunk rather than a separate delta).
      delta = choice["delta"] || {}
      chunk["choices"][0]["delta"]["tool_calls"] = delta["tool_calls"] if delta.key?("tool_calls")
      chunk
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
