# frozen_string_literal: true

require "async"
require "async/http/client"
require "async/http/endpoint"
require "falcon"
require "socket"
require "uri"

# In-process fake upstream + proxy-boot helpers for the streaming-lifecycle
# specs. Unlike spec/support/fake_llama_server (a WEBrick child process, used
# by the supervisor specs), this fixture runs a raw TCP server in-reactor so a
# test can script exact byte-level upstream behavior — stalling mid-stream,
# never responding, or observing when the gateway closes the connection —
# none of which a full HTTP server abstraction exposes directly.
module FakeUpstreamServer
  # A single-connection raw TCP fake upstream. The caller scripts the
  # response by hand (status line, headers, chunked body) after the request
  # head has been drained, then can observe whether the gateway closed the
  # connection (the cancellation signal optiq relies on).
  class RawUpstream
    def initialize(task)
      @task         = task
      @server       = TCPServer.new("127.0.0.1", 0)
      @port         = @server.local_address.ip_port
      @accept_tasks = []
    end

    attr_reader :port

    def base_url
      "http://127.0.0.1:#{@port}"
    end

    # Accepts exactly one connection, drains the request head, then yields
    # the raw socket to the block to script the response. Callable more than
    # once per instance — each call gets its own tracked accept task, so
    # #stop tears all of them down, not just the most recent.
    def accept
      @accept_tasks << @task.async do
        sock = @server.accept
        drain_request_head(sock)
        yield sock
      end
    end

    # Blocks (bounded by timeout) until a read on sock returns EOF, proving
    # the gateway closed its connection to this upstream. Returns true/false.
    def observe_close(sock, timeout: 3)
      @task.with_timeout(timeout) { sock.read(1).nil? }
    rescue Async::TimeoutError
      false
    end

    def stop
      @accept_tasks.each(&:stop)
      @server.close
    end

    private

    def drain_request_head(sock)
      head = +""
      head << sock.readpartial(4096) until head.include?("\r\n\r\n")
      head
    end
  end

  # Runs +example+ inside a fresh reactor, exposed to the example as +@task+.
  # A leaked accept task (the RawUpstream bug this harness guards against)
  # holds the reactor open until its sleep expires rather than failing fast,
  # so once the example returns, any live non-transient child left on +@task+
  # is an orphan: stop it so the reactor closes promptly, then fail loudly
  # instead of letting the leak pass silently. Raising has to happen after
  # the Async block returns — an exception raised inside the task's own
  # block is caught by Async::Task and stored on its promise, never reaching
  # RSpec.
  def run_in_reactor(example)
    orphans = nil

    Async do |task|
      @task = task
      example.run
      orphans = task.children.to_a.reject(&:transient?)
      orphans.each(&:stop)
    end

    return unless orphans&.any?

    raise "leaked #{orphans.size} async task(s) still alive after the example: #{orphans.join(", ")}"
  end

  def sse_headers(sock)
    sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
  end

  # Writes one HTTP/1.1 chunked-encoding frame — the fake upstream speaks raw
  # sockets, not a real HTTP body writer, so chunk framing is hand-rolled.
  def http_chunk(sock, data)
    sock.write("#{data.bytesize.to_s(16)}\r\n#{data}\r\n")
  end

  def end_chunks(sock)
    sock.write("0\r\n\r\n")
  end

  # Minimal fake supervisor double — reports the given alias as already active
  # so ensure_active_if_known is a no-op Success; no subprocess spawns.
  FakeSupervisor = Struct.new(:active_alias, :base_url) do
    include Dry::Monads[:result]

    def running? = true
    def start(_alias_name) = Success(nil)
    def stop = nil
    def swap(to:) = Success(to)
  end

  def fixture_registry
    SpaceInferenceGateway::ModelRegistry.new(
      "default" => "diffusiongemma",
      "models"  => {
        "diffusiongemma" => { "model_path" => "/models/diffusiongemma" },
        "qwen3.6-27b" => { "model_path" => "qwen3.6-27b" },
      },
    )
  end

  def make_app(upstream_client:)
    registry   = fixture_registry
    supervisor = FakeSupervisor.new("diffusiongemma", "http://unused")
    controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)
    SpaceInferenceGateway::App.new(upstream_client: upstream_client, controller: controller)
  end

  # Boot a Falcon/Rack proxy on an ephemeral port using pre-bound sockets.
  # Returns [port, server_task, bound_endpoint].
  def boot_proxy(app)
    base  = Async::HTTP::Endpoint.parse("http://localhost:0")
    bound = base.bound
    port  = bound.sockets.first.local_address.ip_port
    ep    = Async::HTTP::Endpoint.new(URI.parse("http://localhost:#{port}"), bound)
    task  = Falcon::Server.new(Falcon::Server.middleware(app), ep).run
    [port, task, bound]
  end

  def client_for(port)
    Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://localhost:#{port}"))
  end
end
