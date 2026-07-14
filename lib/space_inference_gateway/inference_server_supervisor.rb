# frozen_string_literal: true

require "fileutils"
require "socket"
require "tmpdir"
require "uri"
require "async/semaphore"
require "async/process/child"
require "dry/monads"

module SpaceInferenceGateway
  class InferenceServerSupervisor
    include Dry::Monads[:result]

    Timeouts = Data.define(:readiness, :stop_grace, :poll_interval) do
      def self.default = new(readiness: 120, stop_grace: 5, poll_interval: 0.5)
    end

    def initialize(registry:,
                   log_dir: File.join(Dir.tmpdir, "space-inference-gateway"),
                   timeouts: Timeouts.default)
      @registry      = registry
      @log_dir       = log_dir
      @timeouts      = timeouts
      @swap_sem      = Async::Semaphore.new(1)
      @child         = nil
      @active_alias  = nil
      @active_port   = nil
    end

    def start(alias_name)
      entry = @registry.resolve(alias_name)
      return Failure(:unknown_model) unless entry

      spawn_and_await(entry, alias_name)
    end

    def stop
      return unless @child&.running?

      stop_child(@child)
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
      port  = entry[:port]
      argv  = build_argv(entry)
      child = spawn_child(argv, alias_name)

      result = await_readiness("http://127.0.0.1:#{port}")

      if result.success?
        @child        = child
        @active_alias = alias_name
        @active_port  = port
        Success(base_url: base_url, alias: alias_name)
      else
        stop_child(child)
        result
      end
    rescue Async::TimeoutError
      raise
    rescue StandardError => e
      warn "SPAWN_FAILED: #{e.class}: #{e.message}\n  #{e.backtrace.first(3).join("\n  ")}"
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

    def await_readiness(url)
      deadline = Time.now + @timeouts.readiness

      loop do
        return Failure(:readiness_timeout) if Time.now >= deadline
        return Success() if health_ok?(url)

        Async::Task.current.sleep(@timeouts.poll_interval)
      end
    end

    def health_ok?(url)
      uri    = URI.parse(url)
      socket = TCPSocket.new(uri.host, uri.port)
      socket.write("GET /health HTTP/1.0\r\nHost: #{uri.host}\r\n\r\n")
      socket.flush
      line = socket.gets
      line.to_s.start_with?("HTTP/") && line.include?(" 200 ")
    rescue StandardError
      false
    ensure
      socket&.close
    end

    def stop_child(child)
      return unless child&.running?

      signal_child(child, :TERM)

      deadline = Time.now + @timeouts.stop_grace
      Async::Task.current.sleep(0.05) while child.running? && Time.now < deadline

      return unless child.running?

      signal_child(child, :KILL)
      10.times do
        break unless child.running?

        Async::Task.current.sleep(0.02)
      end
    end

    def signal_child(child, signal)
      child.kill(signal)
    rescue Errno::ESRCH
      nil
    end

    def sanitize(name)
      name.gsub(/[^a-z0-9-]/, "_")
    end
  end
end
