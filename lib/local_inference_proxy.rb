# frozen_string_literal: true

require "async"

module LocalInferenceProxy
  class Forwarder
    DEFAULT_LISTEN_HOST = "127.0.0.1".freeze
    DEFAULT_TARGET_HOST = ENV.fetch("TARGET_HOST", "10.10.4.10").freeze

    def initialize(listen_port:, target_host:, target_port:)
      @listen_port  = listen_port
      @target_host  = target_host
      @target_port  = target_port
    end

    def run
      $stdout.sync = true
      $stderr.sync = true
      server = TCPServer.new(DEFAULT_LISTEN_HOST, @listen_port)
      puts "forwarding #{DEFAULT_LISTEN_HOST}:#{@listen_port} -> #{@target_host}:#{@target_port}"

      Async do |task|
        loop do
          client = server.accept
          task.async { pipe_pair(client) }
        end
      rescue Interrupt
      ensure
        server.close
      end
    end

    private

    def pipe_pair(client)
      upstream_reader, upstream_writer = nil

      begin
        upstream_reader, upstream_writer = TCPSocket.open(@target_host, @target_port)
      rescue Errno::ECONNREFUSED, Errno::ENETUNREACH => e
        $stderr.puts "upstream connect failed: #{e.message}"
        client.close rescue nil
        return
      end

      begin
        child = Async do |task|
          task.async { pipe(client, upstream_writer) }
          pipe(upstream_reader, client)
        end
        child.wait
      rescue Interrupt
      ensure
        upstream_writer&.close rescue nil
        upstream_reader&.close rescue nil
        client&.close rescue nil
      end
    end

    def pipe(from, to)
      while true
        begin
          data = from.readpartial(65536)
        rescue EOFError, Errno::EBADF, Errno::ECONNRESET
          break
        end
        break if data.nil? || data.empty?
        to.write(data)
        to.flush
      end
    rescue Errno::EPIPE
      # pipe target is gone — nothing we can do
    end
  end
end
