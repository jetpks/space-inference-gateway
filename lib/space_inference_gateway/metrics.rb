# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"
require "prometheus/client/data_stores/single_threaded"

module SpaceInferenceGateway
  module Metrics
    # SingleThreaded store: no mutex overhead, fiber-safe under async Ruby.
    # The gateway is single-threaded (one Falcon reactor, cooperative fibers);
    # metric increments do not await so no concurrent access is possible.
    Prometheus::Client.config.data_store = Prometheus::Client::DataStores::SingleThreaded.new

    REGISTRY = Prometheus::Client::Registry.new

    REQUESTS = REGISTRY.counter(
      :sig_requests_total,
      docstring: "Total inference requests",
      labels: %i[flavor stream],
    )

    REQUEST_DURATION = REGISTRY.histogram(
      :sig_request_duration_seconds,
      docstring: "Inference request duration in seconds",
      labels: %i[flavor stream],
      buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 120, 300],
    )

    CHILD_UP = REGISTRY.gauge(
      :sig_child_up,
      docstring: "1 if the inference child process is running, 0 otherwise",
    )

    CHILD_PID = REGISTRY.gauge(
      :sig_child_pid,
      docstring: "PID of the inference child process, 0 when not running",
    )

    CHILD_RSS_BYTES = REGISTRY.gauge(
      :sig_child_rss_bytes,
      docstring: "RSS of the inference child process in bytes (ps -o rss=), 0 when not running",
    )

    CHILD_STARTS = REGISTRY.counter(
      :sig_child_starts_total,
      docstring: "Total number of inference child process starts",
    )

    SWAP_RESULTS = REGISTRY.counter(
      :sig_model_operation_results_total,
      docstring: "Model load/unload operation results",
      labels: %i[operation result],
    )

    ACTIVE_GENERATIONS = REGISTRY.gauge(
      :sig_active_generations,
      docstring: "Number of active streaming generations in flight",
    )

    ACTIVE_MODEL_INFO = REGISTRY.gauge(
      :sig_active_model_info,
      docstring: "Active model info (alias and engine); value is always 1 when loaded",
      labels: %i[alias engine],
    )

    UPSTREAM_ERRORS = REGISTRY.counter(
      :sig_upstream_errors_total,
      docstring: "Upstream errors relayed to clients",
      labels: %i[status flavor],
    )

    KEEPALIVE_COMMENTS = REGISTRY.counter(
      :sig_keepalive_comments_total,
      docstring: "SSE keepalive comments emitted during upstream silence",
      labels: %i[flavor],
    )

    def self.render
      Prometheus::Client::Formats::Text.marshal(REGISTRY)
    end

    # Reads the child process RSS in bytes via `ps -o rss= -p <pid>` (macOS/Linux).
    # Returns 0 when no child pid is present or the ps call fails.
    def self.child_rss_bytes(pid)
      return 0 unless pid

      output = `ps -o rss= -p #{Integer(pid)}`.strip
      output.empty? ? 0 : output.to_i * 1024
    rescue StandardError
      0
    end

    # Updates the active-model info gauge when the active model changes.
    # Clears the previous label combo (sets it to 0) before setting the new one to 1,
    # so at most one label combination has value 1 at any time.
    def self.update_model_info(alias_name, engine)
      new_labels = { alias: alias_name.to_s, engine: engine.to_s }
      ACTIVE_MODEL_INFO.set(0, labels: @last_info_labels) if @last_info_labels && @last_info_labels != new_labels
      ACTIVE_MODEL_INFO.set(1, labels: new_labels)
      @last_info_labels = new_labels
    end

    # Resets all metric stores to zero. Use in tests to ensure isolation.
    def self.reset_all
      REGISTRY.metrics.each do |m|
        store = m.instance_variable_get(:@store)
        store.instance_variable_set(:@internal_store, Hash.new { |h, k| h[k] = 0.0 })
      end
      @last_info_labels = nil
    end
  end
end
