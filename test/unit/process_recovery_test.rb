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

  test "supervisor handles missing process record and fails claimed executions properly" do
    # Start a supervisor with one worker
    @pid = run_supervisor_as_fork(workers: [ { queues: "*", polling_interval: 0.1, processes: 1 } ])
    wait_for_registered_processes(2, timeout: 1.second) # Supervisor + 1 worker

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

    # Wait for the supervisor to reap the worker and fail the job
    wait_while_with_timeout(3.seconds) { SolidQueue::FailedExecution.none? }

    # Assert the execution is failed
    failed_execution = SolidQueue::FailedExecution.last
    assert failed_execution.present?
    assert_equal "SolidQueue::Processes::ProcessExitError", failed_execution.exception_class

    # Ensure supervisor replaces the worker (even though its own record was missing)
    wait_for_registered_processes(2, timeout: 5.seconds)
    assert_operator SolidQueue::Process.where(kind: "Worker").count, :>=, 1
  end
end
