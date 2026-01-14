require "test_helper"

class AsyncSupervisorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "start as non-standalone" do
    supervisor = run_supervisor_as_thread
    wait_for_registered_processes(4, timeout: 10.seconds)

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_id: supervisor.process_id, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)

    supervisor.stop

    assert_no_registered_processes
  end

  test "start standalone" do
    pid = run_supervisor_as_fork(mode: :async)
    wait_for_registered_processes(4, timeout: 10.seconds)

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_pid: pid, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_pid: pid)

    terminate_process(pid)
    assert_no_registered_processes
  end

  test "start as non-standalone with provided configuration" do
    supervisor = run_supervisor_as_thread(workers: [], dispatchers: [ { batch_size: 100 } ])
    wait_for_registered_processes(2, timeout: 10.seconds) # supervisor + dispatcher

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", count: 0)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)

    supervisor.stop

    assert_no_registered_processes
  end

  test "failed orphaned executions as non-standalone" do
    simulate_orphaned_executions 3

    config = {
      workers: [ { queues: "background", polling_interval: 10 } ],
      dispatchers: []
    }

    supervisor = run_supervisor_as_thread(**config)
    wait_for_registered_processes(2, timeout: 10.seconds) # supervisor + 1 worker
    assert_registered_processes(kind: "Supervisor(async)")

    wait_while_with_timeout(1.second) { SolidQueue::ClaimedExecution.count > 0 }

    supervisor.stop

    skip_active_record_query_cache do
      assert_equal 0, SolidQueue::ClaimedExecution.count
      assert_equal 3, SolidQueue::FailedExecution.count
    end
  end

  test "failed orphaned executions as standalone" do
    simulate_orphaned_executions 3

    config = {
      workers: [ { queues: "background", polling_interval: 10 } ],
      dispatchers: []
    }

    pid = run_supervisor_as_fork(mode: :async, **config)
    wait_for_registered_processes(2, timeout: 10.seconds) # supervisor + 1 worker
    assert_registered_processes(kind: "Supervisor(async)")

    wait_while_with_timeout(1.second) { SolidQueue::ClaimedExecution.count > 0 }

    terminate_process(pid)

    skip_active_record_query_cache do
      assert_equal 0, SolidQueue::ClaimedExecution.count
      assert_equal 3, SolidQueue::FailedExecution.count
    end
  end

  private
    def run_supervisor_as_thread(**options)
      SolidQueue::Supervisor.start(mode: :async, standalone: false, **options)
    end

    def simulate_orphaned_executions(count)
      count.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
      process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")

      SolidQueue::ReadyExecution.claim("*", count + 1, process.id)

      assert_equal count, SolidQueue::ClaimedExecution.count
      assert_equal 0, SolidQueue::ReadyExecution.count

      assert_equal [ process.id ], SolidQueue::ClaimedExecution.last(3).pluck(:process_id).uniq

      # Simulate orphaned executions by just wiping the claiming process
      process.delete
    end
end
