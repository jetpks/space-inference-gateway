# frozen_string_literal: true

require "json"
require_relative "reasoning_parser"
require_relative "schemas"

module LocalInferenceProxy
  class AntNormalizer
    def initialize(advertised_model:, supports_reasoning: true)
      @advertised_model   = advertised_model
      @supports_reasoning = supports_reasoning
    end

    # Normalize a non-stream Anthropic message hash.
    # <think> is lifted out of text content blocks into a thinking block.
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
      state = { result: [], text_buffer: +"", in_text: false }
      parse_sse_events(sse_text).each { |ev| process_event(ev, state) }
      state[:result]
    end

    # Returns the full SSE text for an upstream Anthropic SSE stream.
    def normalize_stream_to_sse(sse_text)
      events = normalize_stream_events(sse_text)
      events.map { |ev| "event: #{ev[:event]}\ndata: #{JSON.generate(ev[:data])}\n\n" }.join
    end

    # Incremental streaming entry — pulls raw SSE bytes from upstream_body chunk-by-chunk
    # and yields normalized SSE strings as they become available.
    # Byte-identical to normalize_stream_to_sse when output is concatenated.
    def stream_to_sse(upstream_body)
      state = { result: [], text_buffer: +"", in_text: false }
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

    def process_event(ev, state)
      type = ev[:data]["type"]
      case type
      when "message_start"
        msg = deep_dup(ev[:data]["message"])
        msg["model"] = @advertised_model
        state[:result] << { event: "message_start", data: { "type" => "message_start", "message" => msg } }
      when "content_block_start"
        if ev[:data].dig("content_block", "type") == "text"
          state[:in_text]     = true
          state[:text_buffer] = +""
        end
      when "content_block_delta"
        state[:text_buffer] << ev[:data].dig("delta", "text").to_s if state[:in_text]
      when "content_block_stop"
        if state[:in_text]
          state[:in_text] = false
          state[:result].concat(restructure_text_block(state[:text_buffer]))
        end
      when "message_delta"
        state[:result] << { event: "message_delta", data: ev[:data] }
      when "message_stop"
        state[:result] << { event: "message_stop", data: ev[:data] }
      end
    end

    def build_content_blocks(blocks)
      blocks.flat_map do |block|
        next [block] unless block["type"] == "text"

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
      end
    end

    def restructure_text_block(text)
      return passthrough_text_events(text) unless @supports_reasoning

      parser = ReasoningParser.new
      r      = parser.push(text)
      r2     = parser.flush

      thinking = r[:thinking] + r2[:thinking]
      visible  = r[:visible]  + r2[:visible]

      events  = []
      index   = 0

      unless thinking.empty?
        events << {
          event: "content_block_start",
          data: { "type" => "content_block_start", "index" => index,
"content_block" => { "type" => "thinking", "thinking" => "" }, },
        }
        events << {
          event: "content_block_delta",
          data: { "type" => "content_block_delta", "index" => index,
"delta" => { "type" => "thinking_delta", "thinking" => thinking }, },
        }
        events << {
          event: "content_block_stop",
          data: { "type" => "content_block_stop", "index" => index },
        }
        index += 1
      end

      unless visible.empty?
        events << {
          event: "content_block_start",
          data: { "type" => "content_block_start", "index" => index,
"content_block" => { "type" => "text", "text" => "" }, },
        }
        events << {
          event: "content_block_delta",
          data: { "type" => "content_block_delta", "index" => index,
"delta" => { "type" => "text_delta", "text" => visible }, },
        }
        events << {
          event: "content_block_stop",
          data: { "type" => "content_block_stop", "index" => index },
        }
      end

      events
    end

    def passthrough_text_events(text)
      return [] if text.empty?

      [
        { event: "content_block_start", data: { "type" => "content_block_start", "index" => 0,
"content_block" => { "type" => "text", "text" => "" }, }, },
        { event: "content_block_delta", data: { "type" => "content_block_delta", "index" => 0,
"delta" => { "type" => "text_delta", "text" => text }, }, },
        { event: "content_block_stop",  data: { "type" => "content_block_stop", "index" => 0 } },
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
  end
end
