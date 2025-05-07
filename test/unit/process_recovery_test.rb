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

    supervisor_process = SolidQueue::Process.find_by(kind: "Supervisor", pid: @pid)
    assert supervisor_process

    worker_process = SolidQueue::Process.find_by(kind: "Worker")
    assert worker_process

    # Enqueue a job and manually claim it for the worker to avoid timing races
    job = enqueue_store_result_job(42)
    claimed_execution = SolidQueue::ReadyExecution.claim("*", 5, worker_process.id).first
    assert claimed_execution.present?
    assert_equal worker_process.id, claimed_execution.process_id

    # Simulate supervisor process record disappearing
    supervisor_process.delete
    assert_nil SolidQueue::Process.find_by(id: supervisor_process.id)

    # Terminate the worker process
    worker_pid = worker_process.pid
    terminate_process(worker_pid, signal: :KILL)


    # Wait for the supervisor to reap the worker and fail the job
    wait_for_failed_executions(1, timeout: 5.seconds)

    # Assert the execution is failed
    failed_execution = SolidQueue::FailedExecution.last
    assert failed_execution.present?
    assert_equal "SolidQueue::Processes::ProcessExitError", failed_execution.exception_class

    # Ensure supervisor replaces the worker (even though its own record was missing)
    wait_for_registered_processes(2, timeout: 5.seconds)
    assert_operator SolidQueue::Process.where(kind: "Worker").count, :>=, 1
  end

  private
    def assert_registered_workers_for(*queues, supervisor_pid: nil)
      workers = find_processes_registered_as("Worker")
      registered_queues = workers.map { |process| process.metadata["queues"] }.compact
      assert_equal queues.map(&:to_s).sort, registered_queues.sort
      if supervisor_pid
        assert_equal [ supervisor_pid ], workers.map { |process| process.supervisor.pid }.uniq
      end
    end

    def enqueue_store_result_job(value, queue_name = :default, **options)
      StoreResultJob.set(queue: queue_name).perform_later(value, **options)
    end

    def assert_no_claimed_jobs
      skip_active_record_query_cache do
        assert_empty SolidQueue::ClaimedExecution.all
      end
    end

    def wait_for_claimed_executions(count, timeout: 1.second)
      wait_for(timeout: timeout) { SolidQueue::ClaimedExecution.count == count }
    end

    def wait_for_failed_executions(count, timeout: 1.second)
      wait_for(timeout: timeout) { SolidQueue::FailedExecution.count == count }
    end
end
