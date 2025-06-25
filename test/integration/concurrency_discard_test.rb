# frozen_string_literal: true

require "test_helper"

class ConcurrencyDiscardTest < ActiveSupport::TestCase
  setup do
    @job_result = JobResult.create!(queue_name: "default", status: "test")
  end

  test "discard jobs when concurrency limit is reached with on_conflict: :discard" do
    # Enqueue first job - should be executed
    job1 = DiscardOnConflictJob.perform_later(@job_result.id)

    # Enqueue second job - should be discarded due to concurrency limit
    job2 = DiscardOnConflictJob.perform_later(@job_result.id)

    # Enqueue third job - should also be discarded
    job3 = DiscardOnConflictJob.perform_later(@job_result.id)

    # Check that first job was ready
    solid_job1 = SolidQueue::Job.find_by(active_job_id: job1.job_id)
    assert solid_job1.ready?
    assert solid_job1.ready_execution.present?

    # Check that second and third jobs were discarded
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)
    assert solid_job2.finished?
    assert_nil solid_job2.ready_execution
    assert_nil solid_job2.blocked_execution

    solid_job3 = SolidQueue::Job.find_by(active_job_id: job3.job_id)
    assert solid_job3.finished?
    assert_nil solid_job3.ready_execution
    assert_nil solid_job3.blocked_execution
  end

  test "block jobs when concurrency limit is reached without on_conflict option" do
    # Using SequentialUpdateResultJob which has default blocking behavior
    # Enqueue first job - should be executed
    job1 = SequentialUpdateResultJob.perform_later(@job_result, name: "A")

    # Enqueue second job - should be blocked due to concurrency limit
    job2 = SequentialUpdateResultJob.perform_later(@job_result, name: "B")

    # Check that second job is blocked
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)
    assert solid_job2.blocked?
    assert solid_job2.blocked_execution.present?
  end

  test "respect concurrency limit with discard option" do
    # Enqueue jobs with limit of 2
    job1 = LimitedDiscardJob.perform_later("group1", 1)
    job2 = LimitedDiscardJob.perform_later("group1", 2)
    job3 = LimitedDiscardJob.perform_later("group1", 3) # Should be discarded
    job4 = LimitedDiscardJob.perform_later("group1", 4) # Should be discarded

    # Check that first two jobs are ready
    solid_job1 = SolidQueue::Job.find_by(active_job_id: job1.job_id)
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)
    assert solid_job1.ready?
    assert solid_job2.ready?

    # Check that third and fourth jobs are discarded
    solid_job3 = SolidQueue::Job.find_by(active_job_id: job3.job_id)
    solid_job4 = SolidQueue::Job.find_by(active_job_id: job4.job_id)
    assert solid_job3.finished?
    assert solid_job4.finished?
    assert_nil solid_job3.ready_execution
    assert_nil solid_job4.ready_execution
  end

  test "discard option works with different concurrency keys" do
    # These should not conflict because they have different keys
    job1 = DiscardOnConflictJob.perform_later("key1")
    job2 = DiscardOnConflictJob.perform_later("key2")
    job3 = DiscardOnConflictJob.perform_later("key1") # Should be discarded

    # Check that first two jobs are ready (different keys)
    solid_job1 = SolidQueue::Job.find_by(active_job_id: job1.job_id)
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)
    assert solid_job1.ready?
    assert solid_job2.ready?

    # Check that third job is discarded (same key as first)
    solid_job3 = SolidQueue::Job.find_by(active_job_id: job3.job_id)
    assert solid_job3.finished?
    assert_nil solid_job3.ready_execution
  end

  test "discarded jobs do not unblock other jobs" do
    # Enqueue a job that will be executed
    job1 = DiscardOnConflictJob.perform_later(@job_result.id)

    # Enqueue a job that will be discarded
    job2 = DiscardOnConflictJob.perform_later(@job_result.id)

    # The first job should be ready
    solid_job1 = SolidQueue::Job.find_by(active_job_id: job1.job_id)
    assert solid_job1.ready?

    # The second job should be discarded immediately
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)
    assert solid_job2.finished?

    # Complete the first job and release its lock
    solid_job1.unblock_next_blocked_job
    solid_job1.finished!

    # Enqueue another job - it should be ready since the lock is released
    job3 = DiscardOnConflictJob.perform_later(@job_result.id)
    solid_job3 = SolidQueue::Job.find_by(active_job_id: job3.job_id)
    assert solid_job3.ready?
  end

  test "discarded jobs are marked as finished without execution" do
    # Enqueue a job that will be ready
    job1 = DiscardOnConflictJob.perform_later("test_key")

    # Enqueue a job that will be discarded
    job2 = DiscardOnConflictJob.perform_later("test_key")

    solid_job1 = SolidQueue::Job.find_by(active_job_id: job1.job_id)
    solid_job2 = SolidQueue::Job.find_by(active_job_id: job2.job_id)

    # First job should be ready
    assert solid_job1.ready?
    assert solid_job1.ready_execution.present?

    # Second job should be finished without any execution
    assert solid_job2.finished?
    assert_nil solid_job2.ready_execution
    assert_nil solid_job2.claimed_execution
    assert_nil solid_job2.failed_execution
    assert_nil solid_job2.blocked_execution
  end
end
