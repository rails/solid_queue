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

  test "stop when its registration has been pruned" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.seconds

    supervisor = run_supervisor_as_thread
    wait_for_registered_processes(4, timeout: 3.seconds)

    # Simulate another supervisor pruning this one's registration
    find_processes_registered_as("Supervisor(async)").first.delete

    # The next heartbeat finds the registration gone: the rest of the system
    # already considers this supervisor dead, so it must stop rather than run on
    wait_while_with_timeout(3) { !supervisor.send(:stopped?) }

    assert supervisor.send(:stopped?)

    # The children deregister on the way down, and this supervisor's own row is
    # already gone
    wait_for_registered_processes(0, timeout: 3.seconds)
    assert_no_registered_processes
  ensure
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval if old_heartbeat_interval
    supervisor&.stop
  end

  test "stop when heartbeats stop returning for longer than the alive threshold" do
    old_alive_threshold, SolidQueue.process_alive_threshold = SolidQueue.process_alive_threshold, 0.3.seconds
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.seconds

    # Only the supervisor's heartbeat blocks; the children stay healthy, so the
    # supervisor stopping can only mean its own heartbeat watchdog acted
    unblock_heartbeats = Concurrent::Event.new
    SolidQueue::Process.class_eval do
      alias_method :heartbeat_without_blocking, :heartbeat
      define_method(:heartbeat) do
        kind.start_with?("Supervisor") ? unblock_heartbeats.wait : heartbeat_without_blocking
      end
    end

    supervisor = run_supervisor_as_thread
    wait_while_with_timeout(5) { !supervisor.send(:stopped?) }

    assert supervisor.send(:stopped?)

    # The children deregister on the way down. The supervisor's own stale row
    # may or may not be left: once the local registration is dropped, a last
    # prune can remove it, which is just what another supervisor would do
    wait_while_with_timeout(3) { SolidQueue::Process.where.not(kind: "Supervisor(async)").any? }
    skip_active_record_query_cache do
      assert_empty SolidQueue::Process.where.not(kind: "Supervisor(async)")
    end
  ensure
    unblock_heartbeats.set
    SolidQueue::Process.class_eval do
      if method_defined?(:heartbeat_without_blocking)
        remove_method :heartbeat
        alias_method :heartbeat, :heartbeat_without_blocking
        remove_method :heartbeat_without_blocking
      end
    end
    SolidQueue.process_alive_threshold = old_alive_threshold if old_alive_threshold
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval if old_heartbeat_interval
    supervisor&.stop
  end

  test "stop when maintenance stops returning for longer than the stall threshold" do
    # The heartbeat interval must sit well below the alive threshold: a healthy
    # gap between heartbeat returns is already one interval plus a database
    # round-trip, so equal settings would make the heartbeat watchdog replace
    # perfectly healthy children mid-test
    old_alive_threshold, SolidQueue.process_alive_threshold = SolidQueue.process_alive_threshold, 0.3.seconds
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.seconds

    # A prune that never returns, so the maintenance TimerTask is never
    # rescheduled and this supervisor would silently stop pruning forever
    unblock_prunes = Concurrent::Event.new
    SolidQueue::Supervisor::Maintenance.module_eval do
      alias_method :prune_dead_processes_without_blocking, :prune_dead_processes
      define_method(:prune_dead_processes) { unblock_prunes.wait }
    end

    supervisor = run_supervisor_as_thread
    wait_while_with_timeout(5) { !supervisor.send(:stopped?) }

    assert supervisor.send(:stopped?)

    # The children deregister on the way down; the supervisor's own row cannot
    # be removed -- the prune is what is wedged -- and stays for another
    # supervisor to prune
    wait_for_registered_processes(1, timeout: 3.seconds)
    assert_registered_processes(kind: "Supervisor(async)")
  ensure
    unblock_prunes.set
    SolidQueue::Supervisor::Maintenance.module_eval do
      if private_method_defined?(:prune_dead_processes_without_blocking)
        remove_method :prune_dead_processes
        alias_method :prune_dead_processes, :prune_dead_processes_without_blocking
        remove_method :prune_dead_processes_without_blocking
      end
    end
    SolidQueue.process_alive_threshold = old_alive_threshold if old_alive_threshold
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval if old_heartbeat_interval
    supervisor&.stop
  end

  test "complete shutdown when maintenance stalls and the database is unresponsive" do
    old_alive_threshold, SolidQueue.process_alive_threshold = SolidQueue.process_alive_threshold, 0.3.seconds
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.seconds

    # The same unresponsive database that wedges the prune wedges the
    # deregister on the way out, so shutdown must not attempt it: a supervisor
    # that detects the stall but blocks in its own shutdown never lets whatever
    # runs it start a replacement
    unblock_stalled_calls = Concurrent::Event.new
    SolidQueue::Supervisor::Maintenance.module_eval do
      alias_method :prune_dead_processes_without_blocking, :prune_dead_processes
      define_method(:prune_dead_processes) { unblock_stalled_calls.wait }
    end
    SolidQueue::Process.class_eval do
      alias_method :deregister_without_blocking, :deregister
      define_method(:deregister) do |pruned: false|
        kind.start_with?("Supervisor") ? unblock_stalled_calls.wait : deregister_without_blocking(pruned: pruned)
      end
    end

    supervisor = run_supervisor_as_thread
    supervise_thread = supervisor.instance_variable_get(:@thread)
    wait_while_with_timeout(5) { supervise_thread.alive? }

    assert_not supervise_thread.alive?
  ensure
    unblock_stalled_calls.set
    SolidQueue::Supervisor::Maintenance.module_eval do
      if private_method_defined?(:prune_dead_processes_without_blocking)
        remove_method :prune_dead_processes
        alias_method :prune_dead_processes, :prune_dead_processes_without_blocking
        remove_method :prune_dead_processes_without_blocking
      end
    end
    SolidQueue::Process.class_eval do
      if method_defined?(:deregister_without_blocking)
        remove_method :deregister
        alias_method :deregister, :deregister_without_blocking
        remove_method :deregister_without_blocking
      end
    end
    SolidQueue.process_alive_threshold = old_alive_threshold if old_alive_threshold
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval if old_heartbeat_interval
    supervisor&.stop
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

  test "replace a terminated thread even if releasing its claimed jobs fails" do
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "*", processes: 1 } ], dispatchers: [], skip_recurring: true)
    supervisor = SolidQueue::AsyncSupervisor.new(configuration)

    configured_process = configuration.configured_processes.first
    terminated_thread = stub(kind: "Worker", name: "worker-42", hostname: "localhost", alive?: false)

    supervisor.send(:process_instances)[42] = terminated_thread
    supervisor.send(:configured_processes)[42] = configured_process

    # The database is unreachable when the supervisor tries to fail the
    # terminated thread's claimed jobs, like right after losing its connection
    supervisor.expects(:release_claimed_jobs_by).raises(ActiveRecord::ConnectionNotEstablished.new("connection is closed"))
    supervisor.expects(:start_process).with(configured_process)

    assert_nothing_raised do
      supervisor.send(:check_and_replace_terminated_processes)
    end
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
