require "test_helper"

class SolidQueue::BlockedExecutionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingJob < ApplicationJob
    limits_concurrency key: ->(job_result, **) { job_result }

    def perform(job_result)
    end
  end

  setup do
    @result = JobResult.create!(queue_name: "default")
  end

  teardown do
    SolidQueue::Job.destroy_all
    SolidQueue::Semaphore.delete_all
    JobResult.delete_all
  end

  test "release marks the job as failed and destroys the blocked row when the job class no longer resolves" do
    # Enqueue and consume the semaphore so the next job blocks.
    NonOverlappingJob.perform_later(@result)
    blocking_job = SolidQueue::Job.last
    NonOverlappingJob.perform_later(@result)
    blocked_job = SolidQueue::Job.last
    blocked = blocked_job.blocked_execution
    assert blocked, "expected the second job to be blocked"

    # Simulate the class being renamed/removed between deploys
    blocked_job.update_columns(class_name: "GoneJob")

    assert_difference -> { SolidQueue::BlockedExecution.count } => -1,
                     -> { SolidQueue::FailedExecution.count } => 1 do
      assert_nothing_raised do
        blocked.reload.release
      end
    end

    # No ready execution was promoted — the orphan is now surfaced as a failed execution.
    assert_nil SolidQueue::ReadyExecution.find_by(job_id: blocked_job.id)

    failed = SolidQueue::FailedExecution.find_by(job_id: blocked_job.id)
    assert failed, "expected a failed execution to be created for the orphan"
    assert_equal "SolidQueue::BlockedExecution::JobClassMissingError", failed.exception_class
    assert_match "GoneJob", failed.message
  end
end
