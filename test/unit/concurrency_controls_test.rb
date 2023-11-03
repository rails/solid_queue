require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  class NonOverlappingJob < UpdateResultJob
    include ActiveJob::ConcurrencyControls

    limit_concurrency limit: 1, key: ->(job_result, **) { job_result }
  end

  test "enqueue jobs with concurrency controls" do
    @result = JobResult.create!(queue_name: "default")

    job = NonOverlappingJob.perform_later(@result, name: "A")
    assert_equal 1, job.concurrency_limit
    assert_equal "ConcurrencyControlsTest::NonOverlappingJob/JobResult/#{@result.id}", job.concurrency_key
  end
end
