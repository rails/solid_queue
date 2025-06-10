# frozen_string_literal: true

require "test_helper"

begin
  require "active_job/continuation"
rescue LoadError
  return
end

class ContinuationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    start_processes
    @result = JobResult.create!
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "continuable job completes" do
    ContinuableJob.perform_later(@result)

    wait_for_jobs_to_finish_for(5.seconds)

    assert_no_unfinished_jobs
    assert_last_step :step_two
  end

  test "continuable job can be interrupted and resumed" do
    job = ContinuableJob.perform_later(@result, pause: 0.5.seconds)

    sleep 0.2.seconds
    signal_process(@pid, :TERM)

    wait_for_jobs_to_be_released_for(2.seconds)

    assert_no_claimed_jobs
    assert_unfinished_jobs job
    assert_last_step :step_one

    ActiveJob::QueueAdapters::SolidQueueAdapter.stopping = false
    start_processes
    wait_for_jobs_to_finish_for(5.seconds)

    assert_no_unfinished_jobs
    assert_last_step :step_two
  end

  private
    def assert_last_step(step)
      @result.reload
      assert_equal "stepped", @result.status
      assert_equal step.to_s, @result.value
    end

    def start_processes
      default_worker = { queues: "default", polling_interval: 0.1, processes: 3, threads: 2 }
      dispatcher = { polling_interval: 0.1, batch_size: 200, concurrency_maintenance_interval: 1 }
      @pid = run_supervisor_as_fork(workers: [ default_worker ], dispatchers: [ dispatcher ])
      wait_for_registered_processes(5, timeout: 5.second) # 3 workers working the default queue + dispatcher + supervisor
    end
end
