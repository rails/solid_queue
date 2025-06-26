# frozen_string_literal: true

require "test_helper"

class SolidQueue::BatchTest < ActiveSupport::TestCase
  class TestJob < ApplicationJob
    def perform(value)
      # Simple test job
    end
  end

  class CallbackJob < ApplicationJob
    def perform(batch_id:, **options)
      # Callback test job
    end
  end

  setup do
    @job_args = [
      { value: 1 },
      { value: 2 },
      { value: 3 }
    ]
  end

  test "creates batch with multiple jobs" do
    jobs = @job_args.map { |args| TestJob.new(**args) }

    assert_difference -> { SolidQueue::Batch.count } => 1, -> { SolidQueue::Job.count } => 3 do
      batch = SolidQueue::Batch.enqueue(jobs)
      assert_not_nil batch.batch_id
      assert_equal 3, batch.total_jobs
      assert_equal 3, batch.pending_jobs
      assert_equal 0, batch.completed_jobs
      assert_equal 0, batch.failed_jobs
      assert_equal "pending", batch.status
    end
  end

  test "creates batch with callbacks" do
    jobs = @job_args.map { |args| TestJob.new(**args) }

    batch = SolidQueue::Batch.enqueue(
      jobs,
      on_complete: { job: CallbackJob, args: { type: "complete" } },
      on_success: { job: CallbackJob, args: { type: "success" } },
      on_failure: { job: CallbackJob, args: { type: "failure" } }
    )

    assert_equal "SolidQueue::BatchTest::CallbackJob", batch.on_complete_job_class
    assert_equal({ "type" => "complete" }, batch.on_complete_job_args)
    assert_equal "SolidQueue::BatchTest::CallbackJob", batch.on_success_job_class
    assert_equal({ "type" => "success" }, batch.on_success_job_args)
    assert_equal "SolidQueue::BatchTest::CallbackJob", batch.on_failure_job_class
    assert_equal({ "type" => "failure" }, batch.on_failure_job_args)
  end

  test "creates batch with metadata" do
    jobs = @job_args.map { |args| TestJob.new(**args) }

    batch = SolidQueue::Batch.enqueue(
      jobs,
      metadata: { source: "test", priority: "high", user_id: 123 }
    )

    assert_equal "test", batch.metadata["source"]
    assert_equal "high", batch.metadata["priority"]
    assert_equal 123, batch.metadata["user_id"]
  end

  test "adds jobs to existing batch" do
    jobs = @job_args.first(2).map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(jobs)

    assert_equal 2, batch.total_jobs

    additional_job = TestJob.new(value: 4)
    assert_difference -> { SolidQueue::Job.count } => 1 do
      added_count = batch.add_jobs([ additional_job ])
      assert_equal 1, added_count
    end

    batch.reload
    assert_equal 3, batch.total_jobs
    assert_equal 3, batch.pending_jobs
  end

  test "does not add jobs to finished batch" do
    batch = SolidQueue::Batch.create!(
      status: "completed",
      completed_at: Time.current,
      total_jobs: 1,
      completed_jobs: 1
    )

    additional_job = TestJob.new(value: 4)
    assert_no_difference -> { SolidQueue::Job.count } do
      added_count = batch.add_jobs([ additional_job ])
      assert_equal 0, added_count
    end
  end

  test "tracks job completion" do
    jobs = @job_args.map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(jobs)

    job = batch.jobs.first
    job.finished!

    batch.job_finished!(job)
    batch.reload

    assert_equal 2, batch.pending_jobs
    assert_equal 1, batch.completed_jobs
    assert_equal 0, batch.failed_jobs
    assert_equal "processing", batch.status
  end

  test "tracks job failure" do
    jobs = @job_args.map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(jobs)

    job = batch.jobs.first
    SolidQueue::FailedExecution.create!(job: job, error: "Test error")
    job.finished!

    batch.job_finished!(job)
    batch.reload

    assert_equal 2, batch.pending_jobs
    assert_equal 0, batch.completed_jobs
    assert_equal 1, batch.failed_jobs
    assert_equal "processing", batch.status
  end

  test "completes batch when all jobs succeed" do
    jobs = @job_args.map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(
      jobs,
      on_complete: { job: CallbackJob },
      on_success: { job: CallbackJob }
    )

    # Simulate all jobs completing successfully
    assert_difference -> { SolidQueue::Job.count } => 2 do  # 2 callback jobs
      batch.jobs.each do |job|
        job.finished!
        batch.job_finished!(job)
      end
    end

    batch.reload
    assert_equal "completed", batch.status
    assert_not_nil batch.completed_at
    assert_equal 0, batch.pending_jobs
    assert_equal 3, batch.completed_jobs
    assert_equal 0, batch.failed_jobs

    # Check callbacks were enqueued
    callback_jobs = SolidQueue::Job.where(class_name: "SolidQueue::BatchTest::CallbackJob")
    assert_equal 2, callback_jobs.count  # on_complete and on_success
  end

  test "fails batch when any job fails" do
    jobs = @job_args.map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(
      jobs,
      on_complete: { job: CallbackJob },
      on_failure: { job: CallbackJob }
    )

    # Complete 2 jobs successfully, fail 1
    assert_difference -> { SolidQueue::Job.count } => 2 do  # 2 callback jobs
      batch.jobs.first(2).each do |job|
        job.finished!
        batch.job_finished!(job)
      end

      failed_job = batch.jobs.last
      SolidQueue::FailedExecution.create!(job: failed_job, error: "Test error")
      failed_job.finished!
      batch.job_finished!(failed_job)
    end

    batch.reload
    assert_equal "failed", batch.status
    assert_not_nil batch.completed_at
    assert_equal 0, batch.pending_jobs
    assert_equal 2, batch.completed_jobs
    assert_equal 1, batch.failed_jobs

    # Check callbacks were enqueued
    callback_jobs = SolidQueue::Job.where(class_name: "SolidQueue::BatchTest::CallbackJob")
    assert_equal 2, callback_jobs.count  # on_complete and on_failure
  end

  test "calculates progress percentage" do
    jobs = @job_args.map { |args| TestJob.new(**args) }
    batch = SolidQueue::Batch.enqueue(jobs)

    assert_equal 0.0, batch.progress_percentage

    # Complete one job
    job = batch.jobs.first
    job.finished!
    batch.job_finished!(job)

    batch.reload
    assert_in_delta 33.33, batch.progress_percentage, 0.01

    # Complete remaining jobs
    batch.jobs.where.not(id: job.id).each do |j|
      j.finished!
      batch.job_finished!(j)
    end

    batch.reload
    assert_equal 100.0, batch.progress_percentage
  end

  test "batch scopes" do
    pending_batch = SolidQueue::Batch.create!(status: "pending")
    processing_batch = SolidQueue::Batch.create!(status: "processing")
    completed_batch = SolidQueue::Batch.create!(status: "completed", completed_at: Time.current)
    failed_batch = SolidQueue::Batch.create!(status: "failed", completed_at: Time.current)

    assert_includes SolidQueue::Batch.pending, pending_batch
    assert_includes SolidQueue::Batch.processing, processing_batch
    assert_includes SolidQueue::Batch.completed, completed_batch
    assert_includes SolidQueue::Batch.failed, failed_batch

    assert_includes SolidQueue::Batch.finished, completed_batch
    assert_includes SolidQueue::Batch.finished, failed_batch
    assert_not_includes SolidQueue::Batch.finished, pending_batch
    assert_not_includes SolidQueue::Batch.finished, processing_batch

    assert_includes SolidQueue::Batch.unfinished, pending_batch
    assert_includes SolidQueue::Batch.unfinished, processing_batch
    assert_not_includes SolidQueue::Batch.unfinished, completed_batch
    assert_not_includes SolidQueue::Batch.unfinished, failed_batch
  end

  test "batch relationships" do
    batch = SolidQueue::Batch.create!
    job1 = SolidQueue::Job.create!(
      queue_name: "default",
      class_name: "TestJob",
      batch_id: batch.batch_id
    )
    job2 = SolidQueue::Job.create!(
      queue_name: "default",
      class_name: "TestJob",
      batch_id: batch.batch_id
    )

    assert_equal 2, batch.jobs.count
    assert_includes batch.jobs, job1
    assert_includes batch.jobs, job2
    assert_equal batch.batch_id, job1.batch_id
    assert_equal batch.batch_id, job2.batch_id
  end

  test "perform_batch_later creates batch" do
    assert_difference -> { SolidQueue::Batch.count } => 1, -> { SolidQueue::Job.count } => 3 do
      batch = TestJob.perform_batch_later(@job_args)
      assert_kind_of SolidQueue::Batch, batch
      assert_equal 3, batch.total_jobs
    end
  end

  test "perform_batch_at creates scheduled batch" do
    scheduled_time = 1.hour.from_now

    assert_difference -> { SolidQueue::Batch.count } => 1, -> { SolidQueue::Job.count } => 3 do
      batch = TestJob.perform_batch_at(scheduled_time, @job_args)
      assert_kind_of SolidQueue::Batch, batch
      assert_equal 3, batch.total_jobs

      batch.jobs.each do |job|
        assert_in_delta scheduled_time.to_f, job.scheduled_at.to_f, 1.0
      end
    end
  end

  test "empty batch creation" do
    assert_no_difference -> { SolidQueue::Batch.count } do
      result = SolidQueue::Batch.enqueue([])
      assert_equal 0, result
    end
  end

  test "batch with mixed argument types" do
    # Test with both hash and array arguments
    mixed_args = [
      { value: 1 },
      [ 2 ],
      { value: 3, extra: "data" }
    ]

    jobs = [
      TestJob.new(value: 1),
      TestJob.new(2),
      TestJob.new(value: 3, extra: "data")
    ]

    assert_difference -> { SolidQueue::Job.count } => 3 do
      batch = SolidQueue::Batch.enqueue(jobs)
      assert_equal 3, batch.total_jobs
    end
  end
end
