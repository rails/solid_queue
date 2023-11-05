require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  class NonOverlappingJob < UpdateResultJob
    include ActiveJob::ConcurrencyControls

    limit_concurrency limit: 1, key: ->(job_result, **) { job_result }
  end

  setup do
    @result = JobResult.create!(queue_name: "default")
  end

  test "enqueue jobs with concurrency controls" do
    active_job = NonOverlappingJob.perform_later(@result, name: "A")
    assert_equal 1, active_job.concurrency_limit
    assert_equal "ConcurrencyControlsTest::NonOverlappingJob/JobResult/#{@result.id}", active_job.concurrency_key

    job = SolidQueue::Job.last
    assert_equal active_job.concurrency_limit, job.concurrency_limit
    assert_equal active_job.concurrency_key, job.concurrency_key
  end

  test "blocks jobs when concurrency limits are reached" do
    assert_ready do
      NonOverlappingJob.perform_later(@result, name: "A")
    end

    assert_blocked do
      NonOverlappingJob.perform_later(@result, name: "B")
    end
  end

  private
    def assert_ready(&block)
      assert_difference -> { SolidQueue::ReadyExecution.count }, +1, &block
    end

    def assert_blocked(&block)
      assert_no_difference -> { SolidQueue::ReadyExecution.count } do
        assert_difference -> { SolidQueue::BlockedExecution.count }, +1, &block
      end
    end
end
