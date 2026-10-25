# frozen_string_literal: true

require "fast/completions"
require_relative "upstream_client"

module SpaceInferenceGateway
  # The streaming completions leg's transport (I06, BRIEF §3): rides
  # fast-completions' raw surface (`Fast::Completions::Client#raw_stream`) —
  # one SSE codec, one wire discipline, shared with pi. The gem parses the
  # upstream wire and yields parsed payloads; this seam feeds them to
  # OaiNormalizer#stream_events_to_sse and writes the normalized downstream
  # SSE bytes into a pipe for StreamBody.
  #
  # The control plane and the buffered non-stream path stay on UpstreamClient
  # — out of the gem's charter by design (streaming-only surface).
  #
  # Timeout mapping (the env semantics are load-bearing, BRIEF §3 — the
  # constants and their sizing rationale live on UpstreamClient):
  #   UPSTREAM_IDLE_TIMEOUT    (1400) → raw inactivity_timeout — re-armed
  #                             after every body chunk, so a stream that keeps
  #                             emitting never times out (prefill-sized gaps OK).
  #   UPSTREAM_HEADERS_TIMEOUT (300)  → raw ttfb_timeout — zombie-child
  #                             detection; also bounds the open gate below.
  class RawCompletionsStreamer
    # Engine auth (I06): local engines typically serve unauthenticated; an
    # empty token (the default, UPSTREAM_TOKEN unset) omits the authorization
    # header entirely — byte-identical to the pre-adoption streaming wire.
    # Read per instantiation so specs and embedders can pin the env.
    def self.default_token
      ENV.fetch("UPSTREAM_TOKEN", "")
    end

    # The fast client subclass: rides the gem's request seam (0.6.0's private
    # post_raw_body — payload + the ONE POST) to recover the two observables
    # raw_stream's block contract cannot express: the response object itself
    # (needed to abandon the upstream connection on downstream close — the
    # engine's cancel-generation signal) and the moment its status line +
    # headers arrive (the pre-adoption open gate — keepalives must reach pi
    # during prefill silence, BEFORE the first event; pi aborts at its 300s
    # idle timeout, and optiq spends minutes in prefill emitting zero bytes).
    # If a future gem rename removes the seam, this override stops firing and
    # the open gate falls back to the first event: degraded prefill
    # keepalives, never a hang — and the keepalive spec pins the seam.
    class SignallingClient < Fast::Completions::Client
      def initialize(on_response:, **rest)
        super(**rest)
        @on_response = on_response
      end

      private

      def post_raw_body(body, watchdog)
        response = super
        @on_response.call(response)
        response
      end
    end

    # base_url: String or any callable (#call → String), resolved per open —
    # engine swaps change the URL between requests.
    # idle_timeout / headers_timeout: same names and env-derived defaults as
    # UpstreamClient (whose constants carry the sizing rationale).
    # token: UPSTREAM_TOKEN by default; empty/nil omits the authorization
    # header (the raw surface's api_key: nil discipline).
    def initialize(base_url:, token: self.class.default_token,
                   idle_timeout: UpstreamClient::UPSTREAM_IDLE_TIMEOUT,
                   headers_timeout: UpstreamClient::UPSTREAM_HEADERS_TIMEOUT)
      @base_url        = base_url
      @token           = token
      @idle_timeout    = idle_timeout
      @headers_timeout = headers_timeout
    end

    # Opens a streaming completions request on the raw surface. Blocks the
    # calling fiber until the upstream response headers arrive (or a failure
    # raises the raw surface's own error — Fast::Completions::ApiError |
    # TimeoutError | ConnectionError — for the caller to relay), then returns
    # a session handle: #read_io for the downstream SSE pipe, #close to
    # abandon. The drain task keeps normalizing into the pipe after this
    # returns; the terminal "data: [DONE]" always lands, even for an
    # event-free 2xx body. Mid-stream failures (after headers) surface as a
    # silent pipe EOF — the SSE stream, already 200'd, can only end — with
    # the inactivity timeout observable in /metrics.
    def open(body_str, normalizer:, observer: nil)
      @read_io, @write_io = IO.pipe
      @notification = Async::Notification.new
      @response     = nil
      @open_error   = nil
      @started      = false
      @closed       = false

      @drain_task = Async::Task.current.async do
        event_source = lambda do |&sink|
          client.raw_stream(body_str, ttfb_timeout: @headers_timeout,
                                      inactivity_timeout: @idle_timeout,) do |item|
            mark_started # belt alongside the headers signal: covers a seam rename
            sink.call(item)
          end
        end
        begin
          normalizer.stream_events_to_sse(event_source, observer: observer) { |chunk| @write_io.write(chunk) }
        rescue StandardError => e
          if @started
            Metrics::UPSTREAM_ERRORS.increment(labels: { status: "504" }) if e.is_a?(Fast::Completions::TimeoutError)
          else
            @open_error = e
            mark_started
          end
        ensure
          @write_io.close unless @write_io.closed?
        end
      end

      @notification.wait
      raise @open_error if @open_error

      self
    end

    # Idempotent teardown, never blocking: stop the drain task first (its
    # cancelled read unwinds raw_stream's own ensure ladder, which cannot
    # drain the body on a cancelled task), then close the captured response —
    # public API, "closes the connection as quickly as possible, discarding
    # the body" — which retires the busy pooled connection and closes the
    # SOCKET: the downstream-abandon signal the engine relies on to cancel
    # generation (fast-completions 0.6.0 exposes no abort API, and
    # Client#close would wait on exactly this busy connection). Finally close
    # the client (pool drain — free once the response is retired), then both
    # pipe ends. Mirrors the pre-adoption StreamBody teardown order
    # (response before client) that order was load-bearing for.
    def close
      return if @closed

      @closed = true
      begin
        @drain_task&.stop
        @response&.close
        @client&.close
      ensure
        @write_io.close unless @write_io&.closed?
        @read_io.close unless @read_io&.closed?
      end
    end

    attr_reader :read_io

    # The open gate (I06): unblocks App#open_stream exactly once — at
    # upstream 2xx headers receipt (the signalling client), else at the first
    # raw event, else on failure. A non-2xx response never opens the gate:
    # the signalling client captures nothing and raw_stream raises the mapped
    # ApiError immediately after the seam returns; the drain rescue routes it
    # to the open error path, which signals with the error latched.
    def on_upstream_response(response)
      return unless (200...300).cover?(response.status)

      @response = response
      mark_started
    end

    def mark_started
      return if @started

      @started = true
      @notification.signal
    end

    private

    def client
      # The fast client binds its endpoint at construction, but the engine
      # URL can change per request (model swaps) — build per open, tear down
      # in #close. Path is frozen: POST {base}/v1/chat/completions.
      @client ||= SignallingClient.new(
        base_url:    "#{resolve_base_url.chomp("/")}/v1",
        api_key:     @token.to_s.empty? ? nil : @token,
        on_response: method(:on_upstream_response),
      )
    end

    def resolve_base_url
      @base_url.respond_to?(:call) ? @base_url.call : @base_url
    end
  end
end
