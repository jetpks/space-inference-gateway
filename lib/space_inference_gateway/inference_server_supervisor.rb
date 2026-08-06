# frozen_string_literal: true

require "fileutils"
require "socket"
require "uri"
require "async/semaphore"
require "async/process/child"
require "dry/monads"
require_relative "metrics"

module SpaceInferenceGateway
  class InferenceServerSupervisor
    include Dry::Monads[:result]

    Timeouts = Data.define(:readiness, :stop_grace, :poll_interval, :kill_grace, :probe_timeout) do
      # kill_grace (post-KILL reap wait, and the port-free wait) defaults to
      # stop_grace; probe_timeout (connect+read bound on a single /health or
      # port-liveness check) defaults to 5s. Both overridable, but every
      # existing caller that only names the original three fields keeps working.
      def initialize(readiness:, stop_grace:, poll_interval:, kill_grace: stop_grace, probe_timeout: 5)
        super
      end

      def self.default = new(readiness: 120, stop_grace: 5, poll_interval: 0.5)
    end

    def initialize(registry:,
                   log_dir: default_log_dir,
                   timeouts: Timeouts.default)
      @registry      = registry
      @log_dir       = log_dir
      @timeouts      = timeouts
      @swap_sem      = Async::Semaphore.new(1)
      @child         = nil
      @active_alias  = nil
      @active_port   = nil
      @reaped_ports  = []
    end

    def start(alias_name)
      entry = @registry.resolve(alias_name)
      return Failure(:unknown_model) unless entry

      spawn_and_await(entry, alias_name)
    end

    def stop
      stop_child(@child, @active_port) if @child&.running?
      @child        = nil
      @active_alias = nil
      @active_port  = nil
    end

    def swap(to:)
      @swap_sem.acquire do
        stop
        start(to)
      end
    end

    def running?
      @child&.running? || false
    end

    def pid
      @child&.pid
    end

    def base_url
      "http://127.0.0.1:#{@active_port}" if @active_port
    end

    attr_reader :active_alias

    private

    def spawn_and_await(entry, alias_name)
      port = entry[:port]
      return Failure(:port_in_use) unless port_ready_for_spawn?(port)

      argv   = build_argv(entry)
      child  = spawn_child(argv, alias_name)
      budget = entry[:readiness_timeout] || @timeouts.readiness

      result = await_readiness("http://127.0.0.1:#{port}", budget)

      if result.success?
        @child        = child
        @active_alias = alias_name
        @active_port  = port
        Metrics::CHILD_STARTS.increment
        Success(base_url: base_url, alias: alias_name)
      else
        stop_child(child, port)
        result
      end
    rescue Async::TimeoutError
      raise
    rescue StandardError => e
      warn "SPAWN_FAILED: #{e.class}: #{e.message}\n  #{e.backtrace.first(3).join("\n  ")}"
      stop_child(child, port) if child
      Failure(:spawn_failed)
    end

    def spawn_child(argv, alias_name)
      FileUtils.mkdir_p(@log_dir)
      log_path = File.join(@log_dir, "#{sanitize(alias_name)}.log")
      child = nil
      File.open(log_path, "a") do |log|
        child = Async::Process::Child.new(*argv, out: log, err: log)
      end
      child
    end

    def build_argv(entry)
      case entry[:engine].to_s
      when "optiq" then build_optiq_argv(entry)
      else              build_mlx_argv(entry)
      end
    end

    def build_mlx_argv(entry)
      argv = [
        entry[:venv].to_s, "-m", "mlx_lm.server",
        "--model", entry[:model].to_s,
        "--host", "127.0.0.1",
        "--port", entry[:port].to_s,
      ]
      argv += ["--decode-concurrency", entry[:decode_concurrency].to_s] if entry[:decode_concurrency]
      argv += ["--prompt-concurrency",  entry[:prompt_concurrency].to_s]  if entry[:prompt_concurrency]
      argv += ["--prompt-cache-size",   entry[:prompt_cache_size].to_s]   if entry[:prompt_cache_size]
      argv += Array(entry[:extra_args])
      argv
    end

    # `venv` for optiq is the optiq binary path (e.g. ~/.venv-optiq/bin/optiq),
    # not a python interpreter — the registry expands `~` the same way it does
    # for the mlx venv key.
    def build_optiq_argv(entry)
      argv = [
        entry[:venv].to_s, "serve",
        "--model", entry[:model].to_s,
        "--host", "127.0.0.1",
        "--port", entry[:port].to_s,
      ]
      if entry[:mtp]
        argv << "--mtp"
        argv += ["--mtp-depth", entry[:mtp_depth].to_s] if entry[:mtp_depth]
      end
      argv << "--no-auth"
      argv += ["--max-concurrent", entry[:max_concurrent].to_s] if entry[:max_concurrent]
      argv += Array(entry[:extra_args])
      argv
    end

    def await_readiness(url, budget)
      deadline = Time.now + budget

      loop do
        return Failure(:readiness_timeout) if Time.now >= deadline
        return Success() if health_ok?(url)

        Async::Task.current.sleep(@timeouts.poll_interval)
      end
    end

    # Bounded by probe_timeout (connect + write + read-one-line) so a child
    # that accepts TCP but never writes a response cannot park the readiness
    # loop — or a swap holding @swap_sem — forever.
    def health_ok?(url)
      uri    = URI.parse(url)
      socket = nil
      Async::Task.current.with_timeout(@timeouts.probe_timeout) do
        socket = TCPSocket.new(uri.host, uri.port)
        socket.write("GET /health HTTP/1.0\r\nHost: #{uri.host}\r\n\r\n")
        socket.flush
        line = socket.gets
        line.to_s.start_with?("HTTP/") && line.include?(" 200 ")
      end
    rescue StandardError
      false
    ensure
      socket&.close
    end

    # True if something is currently accepting TCP connections on port —
    # deliberately TCP-level, not /health: used to confirm a predecessor is
    # truly gone (port released) before a successor spawns onto it, not
    # whether it's a healthy engine.
    def port_open?(port)
      Async::Task.current.with_timeout(@timeouts.probe_timeout) do
        TCPSocket.new("127.0.0.1", port).close
        true
      end
    rescue StandardError
      false
    end

    # Polls block (every poll_interval) until it returns true, or timeout
    # elapses. Returns whether it converged.
    def wait_until(timeout)
      deadline = Time.now + timeout
      loop do
        return true if yield
        return false if Time.now >= deadline

        Async::Task.current.sleep(@timeouts.poll_interval)
      end
    end

    # Reaps any pre-existing listener on port that this supervisor instance
    # did not itself spawn — a prior gateway process's orphaned engine child
    # (the studio's launchd-restart case; subsumes the launcher's
    # optiq-only pkill), or a stray process left on a reused port. Looked up
    # via lsof (engine-agnostic — no process-name/pattern matching) and run
    # at most once per port per supervisor instance.
    def reap_stale_listener(port)
      return if @reaped_ports.include?(port)

      @reaped_ports << port
      pids = `lsof -ti tcp:#{Integer(port)} -sTCP:LISTEN 2>/dev/null`.split("\n").filter_map do |s|
        Integer(s, exception: false)
      end
      return if pids.empty?

      pids.each { |pid| signal_pid(pid, :TERM) }
      return if wait_until(@timeouts.stop_grace) { !port_open?(port) }

      pids.each { |pid| signal_pid(pid, :KILL) }
    end

    # AC3/AC6 — a successor is only spawned once the port is verified free,
    # so readiness can't be satisfied by a still-alive predecessor that
    # happens to answer /health on the successor's behalf.
    def port_ready_for_spawn?(port)
      reap_stale_listener(port)
      wait_until(@timeouts.kill_grace) { !port_open?(port) }
    end

    # Verified kill: TERM, wait; escalate to KILL, wait; then confirm the
    # port itself is released — not just that the child object believes
    # itself dead. Every bound wait is finite (stop_grace / kill_grace).
    def stop_child(child, port)
      return unless child&.running?

      signal_child(child, :TERM)
      wait_until(@timeouts.stop_grace) { !child.running? }

      if child.running?
        signal_child(child, :KILL)
        wait_until(@timeouts.kill_grace) { !child.running? }
      end

      wait_until(@timeouts.kill_grace) { !port_open?(port) } if port
    end

    def signal_child(child, signal)
      child.kill(signal)
    rescue Errno::ESRCH
      nil
    end

    def signal_pid(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    def sanitize(name)
      name.gsub(/[^a-z0-9-]/, "_")
    end

    # Stable, human-findable default for engine child stdout+stderr (see
    # #spawn_child), overridable via ENGINE_LOG_DIR — not the ephemeral tmpdir
    # a crash-forensics session would otherwise have to go hunting through.
    # A method (not a constant) so it re-reads ENV on every call, like
    # Timeouts.default above.
    def default_log_dir
      File.expand_path(ENV.fetch("ENGINE_LOG_DIR", "~/Library/Logs/space-inference-gateway"))
    end
  end
end
