# frozen_string_literal: true

module LocalInferenceProxy
  # Streaming-capable extractor that lifts <think>…</think> out of text.
  # Buffers across chunk boundaries so no partial tag ever leaks into
  # visible content.
  #
  # Usage:
  #   parser = ReasoningParser.new
  #   r = parser.push(chunk)   # => { visible: String, thinking: String }
  #   r = parser.flush         # drain any remaining buffered text
  class ReasoningParser
    OPEN_TAG  = "<think>"
    CLOSE_TAG = "</think>"
    # Hold this many chars at end of buffer to guard against split tags.
    OPEN_HOLD  = OPEN_TAG.length  - 1
    CLOSE_HOLD = CLOSE_TAG.length - 1

    def initialize
      @state  = :scanning
      @buffer = +""
    end

    def push(text)
      @buffer << text
      extract
    end

    # Drain remaining buffer as visible text (end of stream).
    def flush
      result = { visible: @buffer.dup, thinking: +"" }
      @buffer.clear
      result
    end

    private

    def extract
      visible  = +""
      thinking = +""

      loop do
        case @state
        when :scanning
          idx = @buffer.index(OPEN_TAG)
          if idx
            visible << @buffer.slice!(0, idx)
            @buffer.slice!(0, OPEN_TAG.length)
            @state = :thinking
          else
            safe = @buffer.length - OPEN_HOLD
            visible << @buffer.slice!(0, safe) if safe.positive?
            break
          end
        when :thinking
          idx = @buffer.index(CLOSE_TAG)
          if idx
            thinking << @buffer.slice!(0, idx)
            @buffer.slice!(0, CLOSE_TAG.length)
            @state = :scanning
          else
            safe = @buffer.length - CLOSE_HOLD
            thinking << @buffer.slice!(0, safe) if safe.positive?
            break
          end
        end
      end

      { visible: visible, thinking: thinking }
    end
  end
end
