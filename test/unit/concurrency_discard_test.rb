# frozen_string_literal: true

require "test_helper"

module SolidQueue
  class ConcurrencyDiscardTest < ActiveSupport::TestCase
    class DiscardOnConflictJob < ApplicationJob
      limits_concurrency to: 1, key: ->(value) { value }, on_conflict: :discard

      def perform(value)
        # Job implementation
      end
    end

    class DefaultBlockingJob < ApplicationJob
      limits_concurrency to: 1, key: ->(value) { value }

      def perform(value)
        # Job implementation
      end
    end

    test "job with on_conflict: :discard is finished when concurrency limit is reached" do
      # Create first job that will acquire the lock
      active_job1 = DiscardOnConflictJob.new("test_key")
      active_job1.job_id = "job1"
      Job.enqueue(active_job1)
      job1 = Job.find_by(active_job_id: active_job1.job_id)

      # First job should be ready
      assert job1.ready?
      assert job1.ready_execution.present?

      # Create second job that should be discarded
      active_job2 = DiscardOnConflictJob.new("test_key")
      active_job2.job_id = "job2"
      Job.enqueue(active_job2)
      job2 = Job.find_by(active_job_id: active_job2.job_id)

      # Second job should be finished without any execution
      assert job2.finished?
      assert_nil job2.ready_execution
      assert_nil job2.blocked_execution
      assert_nil job2.claimed_execution
      assert_nil job2.failed_execution
    end

    test "job without on_conflict option is blocked when concurrency limit is reached" do
      # Create first job that will acquire the lock
      active_job1 = DefaultBlockingJob.new("test_key")
      active_job1.job_id = "job1"
      Job.enqueue(active_job1)
      job1 = Job.find_by(active_job_id: active_job1.job_id)

      # First job should be ready
      assert job1.ready?
      assert job1.ready_execution.present?

      # Create second job that should be blocked
      active_job2 = DefaultBlockingJob.new("test_key")
      active_job2.job_id = "job2"
      Job.enqueue(active_job2)
      job2 = Job.find_by(active_job_id: active_job2.job_id)

      # Second job should be blocked
      assert job2.blocked?
      assert job2.blocked_execution.present?
      assert_nil job2.ready_execution
      assert_not job2.finished?
    end

    test "concurrency_on_conflict attribute is properly set" do
      assert_equal :discard, DiscardOnConflictJob.concurrency_on_conflict
      assert_equal :block, DefaultBlockingJob.concurrency_on_conflict
    end

    test "multiple jobs with same key are discarded when using on_conflict: :discard" do
      # Create first job
      active_job1 = DiscardOnConflictJob.new("shared_key")
      active_job1.job_id = "job1"
      Job.enqueue(active_job1)
      job1 = Job.find_by(active_job_id: active_job1.job_id)

      # Create multiple jobs that should all be discarded
      discarded_jobs = []
      5.times do |i|
        active_job = DiscardOnConflictJob.new("shared_key")
        active_job.job_id = "job#{i + 2}"
        Job.enqueue(active_job)
        job = Job.find_by(active_job_id: active_job.job_id)
        discarded_jobs << job
      end

      # First job should be ready
      assert job1.ready?

      # All other jobs should be finished (discarded)
      discarded_jobs.each do |job|
        assert job.finished?
        assert_nil job.ready_execution
        assert_nil job.blocked_execution
      end
    end

    test "jobs with different keys are not affected by discard" do
      # Create jobs with different keys - they should all be ready
      jobs = []
      3.times do |i|
        active_job = DiscardOnConflictJob.new("key_#{i}")
        active_job.job_id = "job#{i}"
        Job.enqueue(active_job)
        job = Job.find_by(active_job_id: active_job.job_id)
        jobs << job
      end

      # All jobs should be ready since they have different keys
      jobs.each do |job|
        assert job.ready?
        assert job.ready_execution.present?
        assert_not job.finished?
      end
    end

    test "discarded job does not prevent future jobs after lock is released" do
      # Create and finish first job
      active_job1 = DiscardOnConflictJob.new("test_key")
      active_job1.job_id = "job1"
      Job.enqueue(active_job1)
      job1 = Job.find_by(active_job_id: active_job1.job_id)

      # Create second job that gets discarded
      active_job2 = DiscardOnConflictJob.new("test_key")
      active_job2.job_id = "job2"
      Job.enqueue(active_job2)
      job2 = Job.find_by(active_job_id: active_job2.job_id)

      assert job1.ready?
      assert job2.finished? # discarded

      # Release the lock by finishing the first job
      job1.unblock_next_blocked_job
      job1.finished!

      # Create third job - should be ready now
      active_job3 = DiscardOnConflictJob.new("test_key")
      active_job3.job_id = "job3"
      Job.enqueue(active_job3)
      job3 = Job.find_by(active_job_id: active_job3.job_id)

      assert job3.ready?
      assert job3.ready_execution.present?
    end
  end
end
