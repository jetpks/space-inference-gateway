# frozen_string_literal: true

require_relative "metrics"

module SpaceInferenceGateway
  # Per-generation streaming telemetry (I09). Constructed by App#open_stream
  # once the upstream stream is confirmed open (200) and threaded into the
  # normalizer's stream_to_sse*/stream_to_sse_from_oai call so delta/finish/
  # usage events can be tapped without coupling the normalizers to Metrics.
  # +1 prefill at construction; the first observed delta (any channel) flips
  # prefill -> decode and observes time-to-first-token exactly once; #close
  # decrements whichever phase the generation is currently in, including a
  # close with zero deltas (abandon-in-prefill).
  class GenerationObserver
    def initialize(flavor:, t0:)
      @flavor = flavor.to_s
      @t0     = t0
      @phase  = :prefill
      @closed = false

      Metrics::GENERATION_PHASE.increment(labels: { phase: "prefill" })
    end

    # channel ∈ :reasoning/:content/:tool_args — one call per streamed delta event.
    def on_delta(channel)
      Metrics::STREAM_DELTAS.increment(labels: { flavor: @flavor, channel: channel.to_s })
      first_delta!
    end

    # stop_reason: the upstream's verbatim finish/stop reason.
    def on_finish(stop_reason)
      Metrics::GENERATION_STOPS.increment(labels: { flavor: @flavor, stop_reason: stop_reason.to_s })
    end

    # Upstream-reported usage only; nil (absent upstream) contributes nothing.
    def on_usage(prompt: nil, completion: nil)
      Metrics::USAGE_TOKENS.increment(by: prompt, labels: { flavor: @flavor, kind: "prompt" }) if prompt
      Metrics::USAGE_TOKENS.increment(by: completion, labels: { flavor: @flavor, kind: "completion" }) if completion
    end

    def close
      return if @closed

      @closed = true
      Metrics::GENERATION_PHASE.decrement(labels: { phase: @phase.to_s })
    end

    private

    def first_delta!
      return if @phase == :decode

      Metrics::GENERATION_PHASE.decrement(labels: { phase: "prefill" })
      Metrics::GENERATION_PHASE.increment(labels: { phase: "decode" })
      @phase = :decode
      Metrics::TIME_TO_FIRST_TOKEN.observe(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - @t0,
        labels: { flavor: @flavor },
      )
    end
  end
end
