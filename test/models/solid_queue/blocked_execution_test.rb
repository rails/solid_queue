# frozen_string_literal: true

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

  test "release a blocked execution whose job class no longer resolves" do
    NonOverlappingJob.perform_later(@result)
    NonOverlappingJob.perform_later(@result)

    blocked_job = SolidQueue::Job.last
    assert blocked_job.blocked?

    # Simulate the job class being renamed or deleted in a later deploy
    SolidQueue::Job.where(id: blocked_job.id).update_all(class_name: "NoLongerExistingJob")
    semaphore_value = SolidQueue::Semaphore.find_by!(key: blocked_job.concurrency_key).value

    assert SolidQueue::BlockedExecution.release_one(blocked_job.concurrency_key)

    # The execution is promoted to ready, where it will fail on execution and
    # be recorded as failed, instead of being retried by the dispatcher forever
    assert_not SolidQueue::BlockedExecution.exists?(job_id: blocked_job.id)
    assert SolidQueue::ReadyExecution.exists?(job_id: blocked_job.id)

    # Without concurrency limits to check, no semaphore slot is taken
    assert_equal semaphore_value, SolidQueue::Semaphore.find_by!(key: blocked_job.concurrency_key).value
  end
end
