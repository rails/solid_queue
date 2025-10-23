# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "stringio"

class HealthServerTest < ActiveSupport::TestCase
  def setup
    @host = "127.0.0.1"
    @port = available_port(@host)
    @server = SolidQueue::HealthServer.new(host: @host, port: @port, logger: Logger.new(IO::NULL))
    @server.start
    wait_for_server
  end

  def teardown
    @server.stop if defined?(@server)
  end

  def test_health_endpoint_returns_ok
    response = http_get("/health")
    assert_equal "200", response.code
    assert_equal "OK", response.body
  end

  def test_root_endpoint_returns_ok
    response = http_get("/")
    assert_equal "200", response.code
    assert_equal "OK", response.body
  end

  def test_unknown_path_returns_not_found
    response = http_get("/unknown")
    assert_equal "404", response.code
    assert_equal "Not Found", response.body
  end

  def test_stop_stops_server
    assert @server.running?, "server should be running before stop"
    @server.stop
    assert_not @server.running?, "server should not be running after stop"
  ensure
    # Avoid double-stop in teardown if we stopped here
    @server = SolidQueue::HealthServer.new(host: @host, port: @port, logger: Logger.new(IO::NULL))
  end

  def test_engine_skips_starting_health_server_when_puma_plugin_is_active
    SolidQueue.health_server_enabled = true
    SolidQueue.puma_plugin = true

    server = SolidQueue.start_health_server
    assert_nil server
  ensure
    SolidQueue.health_server_enabled = false
    SolidQueue.puma_plugin = false
  end

  def test_logs_warning_when_skipped_under_puma_plugin
    SolidQueue.health_server_enabled = true
    SolidQueue.puma_plugin = true

    original_logger = SolidQueue.logger
    io = StringIO.new
    SolidQueue.logger = Logger.new(io)

    server = SolidQueue.start_health_server
    assert_nil server

    io.rewind
    output = io.read
    assert_includes output, "SolidQueue health server is enabled but Puma plugin is active; skipping starting health server to avoid duplicate servers"
  ensure
    SolidQueue.logger = original_logger if defined?(original_logger)
    SolidQueue.health_server_enabled = false
    SolidQueue.puma_plugin = false
  end

  private
    def http_get(path)
      Net::HTTP.start(@host, @port) do |http|
        http.get(path)
      end
    end

    def wait_for_server
      # Try to connect for up to 1 second
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
      begin
        Net::HTTP.start(@host, @port) { |http| http.head("/") }
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
        retry
      end
    end

    def available_port(host)
      tcp = TCPServer.new(host, 0)
      port = tcp.addr[1]
      tcp.close
      port
    end
end
