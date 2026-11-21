# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module SpaceInferenceGateway
  class OaiNormalizer
    # reasoning_field: the upstream key that carries the reasoning text.
    # mlx uses "reasoning"; a true-OAI upstream (llama-server, tensorfold)
    # uses "reasoning_content". Both are read (see #reasoning_text): a
    # non-nil "reasoning_content" wins, then the configured field.
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

    # The reasoning text an upstream payload carries, whichever standard's
    # key it rides: non-nil "reasoning_content" first (the de-facto OAI
    # extension — tensorfold, llama-server), then the configured mlx field.
    # nil when neither is present → inline <think> lifting.
    def reasoning_text(payload)
      payload["reasoning_content"] || payload[@reasoning_field]
    end

    def normalize_choice(choice)
      msg     = choice["message"] || {}
      content = msg["content"].to_s

      visible  = content
      thinking = ""

      if @supports_reasoning
        native = reasoning_text(msg)
        if native
          thinking = native.to_s
        else
          parser   = ReasoningParser.new
          r        = parser.push(content)
          r2       = parser.flush
          thinking = r[:thinking] + r2[:thinking]
          visible  = r[:visible]  + r2[:visible]
        end
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
      usage = data["usage"]
      observer&.on_usage(prompt: usage["prompt_tokens"], completion: usage["completion_tokens"]) if usage
      chunks = (data["choices"] || []).flat_map { |c| emit_choice(c, base, [canonical, created], parser, observer) }
      # Forward the terminal usage payload (stream_options.include_usage):
      # the choices:[] usage chunk previously vanished client-side (observed
      # for metrics only, never emitted). Absent upstream → nothing emitted.
      return chunks unless usage.is_a?(Hash)

      chunks << base.merge("choices" => [], "usage" => sanitize_usage(usage))
    end

    def emit_choice(choice, base, ids, parser, observer = nil)
      canonical, created = ids
      delta  = choice["delta"] || {}
      result = []

      observer&.on_finish(choice["finish_reason"]) if choice["finish_reason"]
      # One tool_args tap per tool_calls-bearing delta, whichever site emits
      # it, so STREAM_DELTAS stays truthful without double-tapping.
      observer&.on_delta(:tool_args) unless delta["tool_calls"].nil?

      # mlx-vlm ≥ 0.7 ships EVERY field on every delta with explicit nulls
      # (content, reasoning, reasoning_content, tool_calls all present), so
      # branching on key presence misroutes the answer chunk into the
      # reasoning path. Branch on non-nil values instead — measured on the
      # live 0.7.10 wire 2026-10-25, where presence-checking dropped all
      # answer text and spammed tool_calls:null chunks. reasoning_text reads
      # reasoning_content first, so a true-OAI upstream (tensorfold,
      # llama-server) streams its thinking on the same path.
      if !reasoning_text(delta).nil?
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

      result.concat(relay_progressive_tool_calls(choice, base, delta, ids, parser))
    end

    # Verbatim relay for tool_calls deltas WITHOUT finish_reason — qwen-style
    # progressive fragments, one chunk per delta, byte-identical to upstream.
    # A tool_calls delta arriving WITH finish_reason (muse/ATEM terminal
    # shape) is emitted exactly once by finish_chunk's carry — relaying it
    # here too doubled the complete call client-side (I06 gateway-ab).
    def relay_progressive_tool_calls(choice, base, delta, ids, parser)
      return [] if delta["tool_calls"].nil? || choice["finish_reason"]

      result = parser ? flush_chunks(parser.flush, ids.first, ids.last, choice["index"]) : []
      result << base.merge("choices" => [{ "index" => choice["index"],
                                           "delta" => { "tool_calls" => delta["tool_calls"] }, }])
    end

    def emit_reasoning_delta(choice, base)
      delta = choice["delta"] || {}
      rc    = reasoning_text(delta)
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
    end

    def flush_into(result, parser, canonical, created, index)
      return unless parser

      result.concat(flush_chunks(parser.flush, canonical, created, index))
    end

    def finish_chunk(base, choice)
      chunk = base.merge("choices" => [{ "index" => choice["index"], "delta" => {},
                                         "finish_reason" => choice["finish_reason"], }])
      # Carry tool_calls onto the finish chunk when present — for the
      # muse/ATEM terminal shape this carry is the tool_call's SINGLE
      # emission (finish_reason + the complete call on one chunk, the
      # engine's own terminal shape). Value check per 0f81bf6.
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
