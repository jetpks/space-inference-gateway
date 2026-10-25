# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module SpaceInferenceGateway
  class OaiNormalizer
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
      result.concat(flush_stream_tail(parser, canonical, created))

      result
    end

    # Returns the full SSE text (each chunk as "data: ...\n\n", ending with "data: [DONE]\n\n").
    def normalize_stream_to_sse(sse_text)
      chunks = normalize_stream_chunks(sse_text)
      lines  = chunks.map { |c| "data: #{JSON.generate(c)}\n\n" }
      lines << "data: [DONE]\n\n"
      lines.join
    end

    # Incremental streaming entry (I06): pulls PARSED SSE payloads from a
    # raw-surface source — anything callable that yields each parsed data
    # payload (Hash) in arrival order plus the Fast::Completions::SSE::DONE
    # sentinel in wire position, i.e. Client#raw_stream's block contract —
    # and yields normalized SSE strings as they become available. The SSE
    # codec lives in the gem (one codec, one wire discipline, BRIEF §3);
    # this is the consumption side only. Output is byte-identical to
    # normalize_stream_to_sse on the same events (the shared emit_chunks
    # seam does the normalizing for both).
    # observer (I09): optional GenerationObserver tapping deltas/finish/usage.
    # A malformed upstream payload never reaches here — the raw surface
    # repairs-then-drops it (I61); today's text path raised instead.
    def stream_events_to_sse(source, observer: nil)
      parser    = @supports_reasoning ? ReasoningParser.new : nil
      canonical = nil
      created   = nil

      source.call do |item|
        next if item.equal?(Fast::Completions::SSE::DONE)
        next if item["type"] == "diffusion_frame"

        canonical ||= item["id"]
        created   ||= item["created"]
        emit_chunks(item, canonical, created, parser, observer).each do |chunk|
          yield "data: #{JSON.generate(chunk)}\n\n"
        end
      end

      flush_stream_tail(parser, canonical, created).each do |chunk|
        yield "data: #{JSON.generate(chunk)}\n\n"
      end

      yield "data: [DONE]\n\n"
    end

    private

    # The shared stream tail: flush the reasoning parser's remaining buffered
    # content once the upstream events are exhausted (both the buffered
    # text path and the events path land here).
    def flush_stream_tail(parser, canonical, created)
      return [] unless parser && canonical

      flush = parser.flush
      return [] if flush[:thinking].empty? && flush[:visible].empty?

      flush_chunks(flush, canonical, created)
    end

    def parse_sse_data(text)
      text.lines.filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?("data:")

        stripped.sub(/\Adata:\s*/, "")
      end
    end

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

    def base_chunk(canonical_id, created)
      {
        "id" => canonical_id,
        "object" => "chat.completion.chunk",
        "created" => created,
        "model" => @advertised_model,
      }
    end

    def emit_chunks(data, canonical, created, parser, observer = nil)
      base = base_chunk(canonical, created)
      if data["usage"]
        observer&.on_usage(prompt: data.dig("usage", "prompt_tokens"),
                           completion: data.dig("usage", "completion_tokens"),)
      end
      (data["choices"] || []).flat_map { |c| emit_choice(c, base, [canonical, created], parser, observer) }
    end

    def emit_choice(choice, base, ids, parser, observer = nil)
      canonical, created = ids
      delta  = choice["delta"] || {}
      result = []

      observer&.on_finish(choice["finish_reason"]) if choice["finish_reason"]

      # mlx-vlm ≥ 0.7 ships EVERY field on every delta with explicit nulls
      # (content, reasoning, reasoning_content, tool_calls all present), so
      # branching on key presence misroutes the answer chunk into the
      # reasoning path. Branch on non-nil values instead — measured on the
      # live 0.7.10 wire 2026-10-25, where presence-checking dropped all
      # answer text and spammed tool_calls:null chunks.
      if !delta[@reasoning_field].nil?
        observer&.on_delta(:reasoning)
        flush_into(result, parser, canonical, created, choice["index"])
        result.concat(emit_reasoning_delta(choice, base))
      elsif !delta["content"].nil?
        observer&.on_delta(:content)
        result.concat(emit_content_delta(choice, base, canonical, created, parser))
      elsif choice["finish_reason"]
        flush_into(result, parser, canonical, created, choice["index"])
        result << finish_chunk(base, choice)
      else
        result << base.merge("choices" => [{ "index" => choice["index"], "delta" => delta.slice("role") }])
      end

      # mlx emits tool_calls in their own chunk (alongside content or
      # finish_reason); pass them through verbatim so the client can execute.
      # Value check: 0.7.x carries a null tool_calls key on every delta.
      unless delta["tool_calls"].nil?
        observer&.on_delta(:tool_args)
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
      # them from the finish chunk rather than a separate delta). Value check:
      # mlx-vlm 0.7.x carries a null tool_calls key on every delta.
      delta = choice["delta"] || {}
      chunk["choices"][0]["delta"]["tool_calls"] = delta["tool_calls"] unless delta["tool_calls"].nil?
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
