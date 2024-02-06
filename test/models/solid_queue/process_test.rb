require "test_helper"
require "minitest/mock"

class SolidQueue::ProcessTest < ActiveSupport::TestCase
  test "prune processes with expired heartbeats" do
    SolidQueue::Process.register(kind: "Worker", pid: 42)
    SolidQueue::Process.register(kind: "Worker", pid: 43)

    travel_to 10.minutes.from_now

    SolidQueue::Process.register(kind: "Worker", pid: 44)

    assert_difference -> { SolidQueue::Process.count }, -2 do
      SolidQueue::Process.prune
    end
  end

  test "hostname's with special characters are properly loaded" do
    worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: 0.2)
    hostname = "Basecamp’s-Computer"

    Socket.stub :gethostname, hostname.force_encoding("ASCII-8BIT") do
      worker.start
      wait_for_registered_processes(1, timeout: 1.second)
      assert_equal hostname, SolidQueue::Process.last.hostname
    end
  end
end
