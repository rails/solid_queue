require "test_helper"

class AsyncSupervisorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "start as non-standalone" do
    supervisor = run_supervisor_as_thread
    wait_for_registered_processes(4, timeout: 3.seconds) # supervisor + dispatcher + 2 workers

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_id: supervisor.process_id, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)
  ensure
    supervisor.stop
    assert_no_registered_processes
  end

  test "start standalone" do
    pid = run_supervisor_as_fork(mode: :async)
    wait_for_registered_processes(4, timeout: 5.seconds) # supervisor + dispatcher + 2 workers

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_pid: pid, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_pid: pid)

    terminate_process(pid)
    assert_no_registered_processes
  end

  test "start as non-standalone with provided configuration" do
    supervisor = run_supervisor_as_thread(workers: [], dispatchers: [ { batch_size: 100 } ], skip_recurring: false)
    wait_for_registered_processes(3, timeout: 3.seconds) # supervisor + dispatcher + scheduler

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", count: 0)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)
    assert_registered_processes(kind: "Scheduler", supervisor_id: supervisor.process_id)
  ensure
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
    wait_for_registered_processes(2, timeout: 3.seconds) # supervisor + 1 worker
    assert_registered_processes(kind: "Supervisor(async)")

    wait_while_with_timeout(5.seconds) {
      SolidQueue::ClaimedExecution.count > 0 || SolidQueue::FailedExecution.count < 3
    }

    skip_active_record_query_cache do
      assert_equal 0, SolidQueue::ClaimedExecution.count
      assert_equal 3, SolidQueue::FailedExecution.count
    end
  ensure
    supervisor.stop
  end

  test "failed orphaned executions as standalone" do
    simulate_orphaned_executions 3

    config = {
      workers: [ { queues: "background", polling_interval: 10 } ],
      dispatchers: []
    }

    pid = run_supervisor_as_fork(mode: :async, **config)
    wait_for_registered_processes(2, timeout: 3.seconds) # supervisor + 1 worker
    assert_registered_processes(kind: "Supervisor(async)")

    wait_while_with_timeout(5.seconds) {
      SolidQueue::ClaimedExecution.count > 0 || SolidQueue::FailedExecution.count < 3
    }

    terminate_process(pid)

    skip_active_record_query_cache do
      assert_equal 0, SolidQueue::ClaimedExecution.count
      assert_equal 3, SolidQueue::FailedExecution.count
    end
  end

  test "warns on boot when the thread pool is larger than the database connection pool" do
    log = StringIO.new
    with_solid_queue_logger(ActiveSupport::Logger.new(log)) do
      supervisor = run_supervisor_as_thread(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ], dispatchers: [])
      wait_for_registered_processes(2, timeout: 3.seconds) # supervisor + 1 worker
    ensure
      supervisor.stop
    end

    assert_match /Solid Queue needs at least \d+ database connections for the configured workers but the database connection pool is \d+\. Increase it in `config\/database.yml`/, log.string
  end

  test "does not warn on boot when the database connection pool is large enough" do
    log = StringIO.new
    with_solid_queue_logger(ActiveSupport::Logger.new(log)) do
      supervisor = run_supervisor_as_thread(workers: [ { queues: "background", threads: 1, polling_interval: 10 } ], dispatchers: [])
      wait_for_registered_processes(2, timeout: 3.seconds) # supervisor + 1 worker
    ensure
      supervisor.stop
    end

    assert_no_match /the database connection pool is/, log.string
  end

  private
    def run_supervisor_as_thread(**options)
      SolidQueue::Supervisor.start(mode: :async, standalone: false, **options.with_defaults(skip_recurring: true))
    end

    def with_solid_queue_logger(logger)
      old_logger, SolidQueue.logger = SolidQueue.logger, logger
      yield
    ensure
      SolidQueue.logger = old_logger
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
