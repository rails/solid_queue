# frozen_string_literal: true

require "test_helper"

class ProcessRecoveryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = nil
    JobResult.delete_all
  end

  teardown do
    terminate_process(@pid) if @pid
    JobResult.delete_all
  end

  test "alive scheduler whose registration is pruned is torn down and replaced" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 1.second

    @pid = run_supervisor_as_fork(skip_recurring: false)
    wait_for_registered_processes(5, timeout: 3.seconds) # supervisor + 2 workers + dispatcher + scheduler

    scheduler_process = SolidQueue::Process.find_by(kind: "Scheduler")
    assert scheduler_process.present?

    # Simulate another process's prune sweep removing the scheduler's registration
    # while the scheduler itself is still alive
    scheduler_process.delete

    # The scheduler should notice its registration is gone on its next heartbeat,
    # terminate, and be replaced by the supervisor with a fresh registration
    wait_while_with_timeout(10.seconds) do
      skip_active_record_query_cache do
        SolidQueue::Process.where(kind: "Scheduler").where.not(id: scheduler_process.id).none?
      end
    end

    skip_active_record_query_cache do
      new_scheduler_process = SolidQueue::Process.where(kind: "Scheduler").last
      assert new_scheduler_process.present?
      assert_not_equal scheduler_process.id, new_scheduler_process.id
    end
  ensure
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval
  end

  test "supervisor handles missing process record and fails claimed executions properly" do
    # Start a supervisor with one worker
    @pid = run_supervisor_as_fork(workers: [ { queues: "*", polling_interval: 0.1, processes: 1 } ])
    wait_for_registered_processes(2, timeout: 3.seconds) # Supervisor + 1 worker

    supervisor_process = SolidQueue::Process.find_by(kind: "Supervisor(fork)", pid: @pid)
    assert supervisor_process

    # Find the worker supervised by this specific supervisor to avoid interference from other tests
    worker_process = SolidQueue::Process.find_by(kind: "Worker", supervisor_id: supervisor_process.id)
    assert worker_process

    # Enqueue a job and wait for it to be claimed
    StoreResultJob.perform_later(42, pause: 10.seconds)
    wait_while_with_timeout(3.seconds) { SolidQueue::ClaimedExecution.none? }

    claimed_execution = SolidQueue::ClaimedExecution.last
    assert claimed_execution.present?
    assert_equal worker_process.id, claimed_execution.process_id

    # Simulate supervisor process record disappearing
    supervisor_process.delete
    assert_nil SolidQueue::Process.find_by(id: supervisor_process.id)

    # Terminate the worker process
    worker_pid = worker_process.pid
    terminate_process(worker_pid, signal: :KILL)

    # Wait for the supervisor to reap the worker and fail the job. The
    # supervisor only checks for terminated forks about once a second, so give
    # it enough margin for a couple of cycles even on a slow runner.
    wait_while_with_timeout(10.seconds) { SolidQueue::FailedExecution.none? }

    # Assert the execution is failed
    failed_execution = SolidQueue::FailedExecution.last
    assert failed_execution.present?
    assert_equal "SolidQueue::Processes::ProcessExitError", failed_execution.exception_class

    # Ensure supervisor replaces the worker (even though its own record was missing)
    wait_for_registered_processes(2, timeout: 5.seconds)
    assert_operator SolidQueue::Process.where(kind: "Worker").count, :>=, 1
  end
end
