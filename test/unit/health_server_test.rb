# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "stringio"

class HealthServerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
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

  def test_supervisor_starts_health_server_from_configuration
    @server.stop # ensure no unsupervised health server is registered
    other_port = available_port(@host)
    pid = run_supervisor_as_fork(health_server: { host: @host, port: other_port }, workers: [], dispatchers: [])
    wait_for_registered_processes(2, timeout: 2) # supervisor + health server

    assert_registered_processes(kind: "HealthServer", count: 1)

    # Verify it responds to HTTP
    wait_for_server_on(other_port)
    response = http_get_on(other_port, "/health")
    assert_equal "200", response.code
    assert_equal "OK", response.body
  ensure
    terminate_process(pid) if pid
  end

  def test_supervisor_skips_health_server_when_puma_plugin_is_active
    SolidQueue.puma_plugin = true

    original_logger = SolidQueue.logger
    SolidQueue.logger = ActiveSupport::Logger.new($stdout)

    @server.stop # ensure no unsupervised health server is registered
    pid = nil
    pid = run_supervisor_as_fork(health_server: { host: @host, port: available_port(@host) }, workers: [], dispatchers: [])
    # Expect only supervisor to register
    wait_for_registered_processes(1, timeout: 2)
    assert_equal 0, find_processes_registered_as("HealthServer").count
  ensure
    SolidQueue.logger = original_logger if defined?(original_logger)
    SolidQueue.puma_plugin = false
    terminate_process(pid) if pid
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

    def wait_for_server_on(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
      begin
        Net::HTTP.start(@host, port) { |http| http.head("/") }
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
        retry
      end
    end

    def http_get_on(port, path)
      Net::HTTP.start(@host, port) do |http|
        http.get(path)
      end
    end

    def available_port(host)
      tcp = TCPServer.new(host, 0)
      port = tcp.addr[1]
      tcp.close
      port
    end
end
