# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module SpaceInferenceGateway
  class AntNormalizer # rubocop:disable Metrics/ClassLength
    # reasoning_field: the upstream OAI key that carries reasoning text (mlx: "reasoning").
    def initialize(advertised_model:, supports_reasoning: true, reasoning_field: "reasoning")
      @advertised_model   = advertised_model
      @supports_reasoning = supports_reasoning
      @reasoning_field    = reasoning_field
    end

    # Normalize a non-stream Anthropic message hash.
    # Native thinking blocks are conformed (signature stripped); inline <think> is lifted.
    def normalize(input)
      content_blocks = build_content_blocks(input["content"] || [])

      {
        "id" => input["id"],
        "type" => "message",
        "role" => "assistant",
        "content" => content_blocks,
        "model" => @advertised_model,
        "stop_reason" => input["stop_reason"],
        "stop_sequence" => input["stop_sequence"],
        "usage" => sanitize_usage(input["usage"]),
      }
    end

    # Feed raw SSE text from the upstream; returns array of normalized events.
    # Each event is { event: String, data: Hash }.
    # Handles Anthropic's message_start / content_block_* / message_delta / message_stop.
    def normalize_stream_events(sse_text)
      state = init_stream_state
      parse_sse_events(sse_text).each { |ev| process_event(ev, state) }
      state[:result]
    end

    # Returns the full SSE text for an upstream Anthropic SSE stream.
    def normalize_stream_to_sse(sse_text)
      events = normalize_stream_events(sse_text)
      events.map { |ev| "event: #{ev[:event]}\ndata: #{JSON.generate(ev[:data])}\n\n" }.join
    end

    # Normalize an OAI chat.completion (from mlx) into an Anthropic message hash.
    # Reads @reasoning_field from the OAI message; emits thinking + text blocks.
    def normalize_oai(oai_response)
      choice = (oai_response["choices"] || []).first || {}
      msg    = choice["message"] || {}

      thinking, visible = extract_oai_reasoning(msg)

      blocks = []
      blocks << { "type" => "thinking", "thinking" => thinking } unless thinking.empty?
      blocks << { "type" => "text",     "text"     => visible  } if !visible.empty? || thinking.empty?
      blocks.concat(oai_tool_calls_to_ant(msg["tool_calls"])) if msg["tool_calls"]

      {
        "id" => oai_response["id"],
        "type" => "message",
        "role" => "assistant",
        "content" => blocks,
        "model" => @advertised_model,
        "stop_reason" => oai_finish_to_ant(choice["finish_reason"]),
        "stop_sequence" => nil,
        "usage" => oai_usage_to_ant(oai_response["usage"]),
      }
    end

    # Collect OAI SSE text into normalized Anthropic event hashes (batch mode).
    def normalize_stream_events_from_oai(sse_text)
      events = []
      fake_body = Enumerator.new { |y| y << sse_text }
      stream_to_sse_from_oai(fake_body) do |ev_str|
        lines      = ev_str.strip.lines.map(&:strip)
        event_name = lines.find { |l| l.start_with?("event:") }&.sub(/\Aevent:\s*/, "")
        data_line  = lines.find { |l| l.start_with?("data:") }&.sub(/\Adata:\s*/, "")
        events << { event: event_name, data: JSON.parse(data_line) } if data_line
      end
      events
    end

    # Incremental OAI SSE → Anthropic SSE conversion (mlx engine path).
    # Reads delta[@reasoning_field] for reasoning, delta["content"] for text.
    # Yields ANT-format "event: ...\ndata: ...\n\n" strings.
    def stream_to_sse_from_oai(upstream_body, &block)
      state = init_oai_to_ant_state
      buf   = +""

      upstream_body.each do |raw_chunk|
        buf << raw_chunk
        while (idx = buf.index("\n\n"))
          line_block = buf.slice!(0, idx + 2)
          line_block.each_line do |line|
            line = line.strip
            next unless line.start_with?("data:")

            raw = line.sub(/\Adata:\s*/, "")
            next if raw == "[DONE]"

            data = JSON.parse(raw)
            next if data["type"] == "diffusion_frame"

            process_oai_chunk(data, state, &block)
          end
        end
      end
    end

    # Incremental streaming entry — pulls raw SSE bytes from upstream_body chunk-by-chunk
    # and yields normalized SSE strings as they become available.
    # Byte-identical to normalize_stream_to_sse when output is concatenated.
    def stream_to_sse(upstream_body)
      state = init_stream_state
      buf   = +""

      upstream_body.each do |raw_chunk|
        buf << raw_chunk

        while (idx = buf.index("\n\n"))
          event_block = buf.slice!(0, idx + 2)
          ev = parse_sse_block(event_block)
          next unless ev[:data]

          process_event(ev, state)

          state[:result].each do |evt|
            yield "event: #{evt[:event]}\ndata: #{JSON.generate(evt[:data])}\n\n"
          end
          state[:result].clear
        end
      end
    end

    private

    def init_stream_state
      {
        result: [], text_buffer: +"", in_text: false,
        thinking_buffer: +"", in_thinking: false, native_thinking: false,
      }
    end

    def process_event(ev, state)
      case ev[:data]["type"]
      when "message_start"       then handle_message_start(ev, state)
      when "content_block_start" then handle_block_start(ev, state)
      when "content_block_delta" then handle_block_delta(ev, state)
      when "content_block_stop"  then handle_block_stop(state)
      when "message_delta"       then state[:result] << { event: "message_delta", data: ev[:data] }
      when "message_stop"        then state[:result] << { event: "message_stop",  data: ev[:data] }
      end
    end

    def handle_message_start(ev, state)
      msg = deep_dup(ev[:data]["message"])
      msg["model"] = @advertised_model
      state[:result] << { event: "message_start", data: { "type" => "message_start", "message" => msg } }
    end

    def handle_block_start(ev, state)
      case ev[:data].dig("content_block", "type")
      when "thinking"
        state[:in_thinking] = true
        state[:native_thinking] = true
        state[:thinking_buffer] = +""
      when "text"
        state[:in_text]     = true
        state[:text_buffer] = +""
      end
    end

    def handle_block_delta(ev, state)
      delta = ev[:data]["delta"]
      case delta&.fetch("type", nil)
      when "thinking_delta" then state[:thinking_buffer] << delta["thinking"].to_s if state[:in_thinking]
      when "text_delta"     then state[:text_buffer] << delta["text"].to_s if state[:in_text]
      end
    end

    def handle_block_stop(state)
      if state[:in_thinking]
        state[:in_thinking] = false
        state[:result].concat(emit_thinking_events(state[:thinking_buffer]))
      elsif state[:in_text]
        state[:in_text] = false
        events = if state[:native_thinking]
                   passthrough_text_events(state[:text_buffer], index: 1)
                 else
                   restructure_text_block(state[:text_buffer])
                 end
        state[:result].concat(events)
      end
    end

    def build_content_blocks(blocks)
      blocks.flat_map do |block|
        case block["type"]
        when "thinking"
          [{ "type" => "thinking", "thinking" => block["thinking"].to_s }]
        when "text"
          text = block["text"].to_s
          next [{ "type" => "text", "text" => text }] unless @supports_reasoning

          parser = ReasoningParser.new
          r      = parser.push(text)
          r2     = parser.flush

          thinking = r[:thinking] + r2[:thinking]
          visible  = r[:visible]  + r2[:visible]

          out = []
          out << { "type" => "thinking", "thinking" => thinking } unless thinking.empty?
          out << { "type" => "text",     "text"     => visible  } unless visible.empty?
          out
        else
          [block]
        end
      end
    end

    def restructure_text_block(text)
      return passthrough_text_events(text) unless @supports_reasoning

      parser = ReasoningParser.new
      r      = parser.push(text)
      r2     = parser.flush

      thinking = r[:thinking] + r2[:thinking]
      visible  = r[:visible]  + r2[:visible]

      emit_thinking_events(thinking) + passthrough_text_events(visible, index: thinking.empty? ? 0 : 1)
    end

    def emit_thinking_events(thinking)
      return [] if thinking.empty?

      [
        { event: "content_block_start", data: { "type" => "content_block_start", "index" => 0,
"content_block" => { "type" => "thinking", "thinking" => "" }, }, },
        { event: "content_block_delta", data: { "type" => "content_block_delta", "index" => 0,
"delta" => { "type" => "thinking_delta", "thinking" => thinking }, }, },
        { event: "content_block_stop",  data: { "type" => "content_block_stop", "index" => 0 } },
      ]
    end

    def passthrough_text_events(text, index: 0)
      return [] if text.empty?

      [
        { event: "content_block_start", data: { "type" => "content_block_start", "index" => index,
"content_block" => { "type" => "text", "text" => "" }, }, },
        { event: "content_block_delta", data: { "type" => "content_block_delta", "index" => index,
"delta" => { "type" => "text_delta", "text" => text }, }, },
        { event: "content_block_stop",  data: { "type" => "content_block_stop", "index" => index } },
      ]
    end

    def parse_sse_block(text)
      current = {}
      text.each_line do |line|
        line = line.chomp
        if line.start_with?("event:")
          current[:event] = line.sub(/\Aevent:\s*/, "")
        elsif line.start_with?("data:")
          current[:data] = JSON.parse(line.sub(/\Adata:\s*/, ""))
        end
      end
      current
    end

    def parse_sse_events(text)
      events  = []
      current = {}

      text.lines.each do |line|
        line = line.chomp
        if line.start_with?("event:")
          current[:event] = line.sub(/\Aevent:\s*/, "")
        elsif line.start_with?("data:")
          raw = line.sub(/\Adata:\s*/, "")
          current[:data] = JSON.parse(raw)
        elsif line.empty? && current[:data]
          events << current
          current = {}
        end
      end

      events << current if current[:data]
      events
    end

    def sanitize_usage(usage)
      return {} unless usage.is_a?(Hash)

      out = {
        "input_tokens" => usage["input_tokens"].to_i,
        "output_tokens" => usage["output_tokens"].to_i,
      }
      %w[cache_creation_input_tokens cache_read_input_tokens].each do |k|
        out[k] = usage[k].to_i if usage.key?(k)
      end
      out
    end

    def deep_dup(obj)
      JSON.parse(JSON.generate(obj))
    end

    # ── OAI→ANT helpers ──────────────────────────────────────────────────────

    def extract_oai_reasoning(msg)
      content = msg["content"].to_s
      if @supports_reasoning && msg.key?(@reasoning_field) && !msg[@reasoning_field].to_s.empty?
        [msg[@reasoning_field].to_s, content]
      elsif @supports_reasoning
        parser = ReasoningParser.new
        r      = parser.push(content)
        r2     = parser.flush
        [r[:thinking] + r2[:thinking], r[:visible] + r2[:visible]]
      else
        ["", content]
      end
    end

    # OAI message.tool_calls -> ANT tool_use blocks (AC5). function.arguments is a
    # JSON string; parsed to an object, falling back to {} on parse failure or a
    # non-object result (the schema requires input to be an object).
    def oai_tool_calls_to_ant(tool_calls)
      tool_calls.map do |tc|
        fn = tc["function"] || {}
        { "type" => "tool_use", "id" => ant_tool_id(tc["id"]), "name" => fn["name"],
          "input" => parse_tool_arguments(fn["arguments"]), }
      end
    end

    def parse_tool_arguments(arguments)
      parsed = JSON.parse(arguments.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Anthropic tool_use ids are expected to carry the "toolu_" prefix; CC sends
    # the id back verbatim as tool_result.tool_use_id, so it must round-trip.
    def ant_tool_id(oai_id)
      "toolu_#{oai_id}"
    end

    def oai_finish_to_ant(finish_reason)
      case finish_reason
      when "stop"       then "end_turn"
      when "length"     then "max_tokens"
      when "tool_calls" then "tool_use"
      else finish_reason
      end
    end

    def oai_usage_to_ant(usage)
      return { "input_tokens" => 0, "output_tokens" => 0 } unless usage.is_a?(Hash)

      {
        "input_tokens" => usage["prompt_tokens"].to_i,
        "output_tokens" => usage["completion_tokens"].to_i,
      }
    end

    def init_oai_to_ant_state
      {
        started:       false,
        in_reasoning:  false,
        in_text:       false,
        next_index:    0,
        reasoning_idx: nil,
        text_idx:      nil,
        id:            nil,
        tool_calls:    {}, # oai tool_calls[].index => { ant_index:, started: }
      }
    end

    def process_oai_chunk(data, state, &block)
      state[:id] ||= data["id"]

      choice = (data["choices"] || []).first
      return unless choice

      delta = choice["delta"] || {}
      emit_oai_message_start(state, block) unless state[:started]

      emit_oai_reasoning_or_content_delta(state, delta, block)
      emit_oai_tool_call_deltas(state, delta["tool_calls"], block) if delta["tool_calls"]
      emit_oai_finish(state, choice["finish_reason"], block) if choice["finish_reason"]
    end

    def emit_oai_reasoning_or_content_delta(state, delta, block)
      reasoning_text = delta.key?(@reasoning_field) ? delta[@reasoning_field] : nil
      content_text   = delta.key?("content") ? delta["content"] : nil

      if !reasoning_text.nil?
        emit_oai_reasoning_delta(state, reasoning_text, block)
      elsif !content_text.nil?
        emit_oai_content_delta(state, content_text, block)
      end
    end

    def emit_oai_message_start(state, block)
      state[:started] = true
      emit_ant(block, "message_start", {
                 "type" => "message_start",
        "message" => {
          "id" => state[:id], "type" => "message", "role" => "assistant",
          "content" => [], "model" => @advertised_model,
          "stop_reason" => nil, "stop_sequence" => nil,
          "usage" => { "input_tokens" => 0, "output_tokens" => 0 },
        },
               })
    end

    def emit_oai_reasoning_delta(state, text, block)
      unless state[:in_reasoning]
        state[:in_reasoning]  = true
        state[:reasoning_idx] = state[:next_index]
        state[:next_index]   += 1
        emit_ant(block, "content_block_start", {
                   "type" => "content_block_start", "index" => state[:reasoning_idx],
          "content_block" => { "type" => "thinking", "thinking" => "" },
                 })
      end
      emit_ant(block, "content_block_delta", {
                 "type" => "content_block_delta", "index" => state[:reasoning_idx],
        "delta" => { "type" => "thinking_delta", "thinking" => text.to_s },
               })
    end

    def emit_oai_content_delta(state, text, block)
      if state[:in_reasoning]
        state[:in_reasoning] = false
        emit_ant(block, "content_block_stop", {
                   "type" => "content_block_stop", "index" => state[:reasoning_idx],
                 })
      end
      unless state[:in_text]
        state[:in_text]    = true
        state[:text_idx]   = state[:next_index]
        state[:next_index] += 1
        emit_ant(block, "content_block_start", {
                   "type" => "content_block_start", "index" => state[:text_idx],
          "content_block" => { "type" => "text", "text" => "" },
                 })
      end
      emit_ant(block, "content_block_delta", {
                 "type" => "content_block_delta", "index" => state[:text_idx],
        "delta" => { "type" => "text_delta", "text" => text.to_s },
               })
    end

    # AC4: each OAI tool_calls[] entry (keyed by its "index") becomes one ANT
    # tool_use content block. The first delta for a given index carries id/name
    # (content_block_start); every delta carrying function.arguments — whole or
    # fragmented — is relayed as its own input_json_delta. Any open reasoning/text
    # block is closed first (block sequencing: text-then-tool_use is the common case).
    def emit_oai_tool_call_deltas(state, tool_calls, block)
      close_oai_text_blocks(state, block)

      tool_calls.each do |tc|
        entry = (state[:tool_calls][tc["index"]] ||= {})

        unless entry[:started]
          entry[:started]   = true
          entry[:ant_index] = state[:next_index]
          state[:next_index] += 1
          emit_ant(block, "content_block_start", {
                     "type" => "content_block_start", "index" => entry[:ant_index],
            "content_block" => { "type" => "tool_use", "id" => ant_tool_id(tc["id"]),
                                  "name" => tc.dig("function", "name"), "input" => {}, },
                   })
        end

        args = tc.dig("function", "arguments")
        next if args.nil?

        emit_ant(block, "content_block_delta", {
                   "type" => "content_block_delta", "index" => entry[:ant_index],
          "delta" => { "type" => "input_json_delta", "partial_json" => args.to_s },
                 })
      end
    end

    def close_oai_text_blocks(state, block)
      if state[:in_reasoning]
        state[:in_reasoning] = false
        emit_ant(block, "content_block_stop", {
                   "type" => "content_block_stop", "index" => state[:reasoning_idx],
                 })
      end
      return unless state[:in_text]

      state[:in_text] = false
      emit_ant(block, "content_block_stop", {
                 "type" => "content_block_stop", "index" => state[:text_idx],
               })
    end

    def emit_oai_finish(state, finish_reason, block)
      stop_reason = oai_finish_to_ant(finish_reason)
      close_oai_text_blocks(state, block)
      state[:tool_calls].each_value do |entry|
        next unless entry[:started]

        emit_ant(block, "content_block_stop", { "type" => "content_block_stop", "index" => entry[:ant_index] })
      end
      emit_ant(block, "message_delta", {
                 "type" => "message_delta",
        "delta" => { "stop_reason" => stop_reason, "stop_sequence" => nil },
        "usage" => { "output_tokens" => 0 },
               })
      emit_ant(block, "message_stop", { "type" => "message_stop" })
    end

    def emit_ant(block, event, data)
      block.call("event: #{event}\ndata: #{JSON.generate(data)}\n\n")
    end
  end
end
