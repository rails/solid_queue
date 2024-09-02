require "test_helper"
require "minitest/mock"

class SolidQueue::ProcessTest < ActiveSupport::TestCase
  test "prune processes with expired heartbeats" do
    SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-42")
    SolidQueue::Process.register(kind: "Worker", pid: 43, name: "worker-43")

    travel_to 10.minutes.from_now

    SolidQueue::Process.register(kind: "Worker", pid: 44, name: "worker-44")

    assert_difference -> { SolidQueue::Process.count }, -2 do
      SolidQueue::Process.prune
    end
  end

  test "prune processes with expired heartbeats and fail claimed executions" do
    process = SolidQueue::Process.register(kind: "Worker", pid: 43, name: "worker-43")
    3.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
    jobs = SolidQueue::Job.last(3)

    SolidQueue::ReadyExecution.claim("*", 5, process.id)

    travel_to 10.minutes.from_now

    assert_difference -> { SolidQueue::FailedExecution.count }, 3 do
      assert_difference -> { SolidQueue::ClaimedExecution.count }, -3 do
        SolidQueue::Process.prune
      end
    end

    jobs.each(&:reload)
    assert jobs.all?(&:failed?)
  end

  test "prune processes including their supervisor with expired heartbeats and fail claimed executions" do
    supervisor = SolidQueue::Process.register(kind: "Supervisor", pid: 42, name: "supervisor-42")
    process = SolidQueue::Process.register(kind: "Worker", pid: 43, name: "worker-43", supervisor_id: supervisor.id)
    3.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
    jobs = SolidQueue::Job.last(3)

    SolidQueue::ReadyExecution.claim("*", 5, process.id)

    travel_to 10.minutes.from_now

    assert_difference -> { SolidQueue::Process.count }, -2 do
      assert_difference -> { SolidQueue::FailedExecution.count }, 3 do
        assert_difference -> { SolidQueue::ClaimedExecution.count }, -3 do
          SolidQueue::Process.prune
        end
      end
    end

    jobs.each(&:reload)
    assert jobs.all?(&:failed?)
  end

  test "hostname's with special characters are properly loaded" do
    worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: 0.2)
    hostname = "Basecamp’s-Computer"

    Socket.stub :gethostname, hostname.force_encoding("ASCII-8BIT") do
      worker.start
      wait_for_registered_processes(1, timeout: 1.second)

      assert_equal hostname, SolidQueue::Process.last.hostname

      worker.stop
    end
  end
end
