require "test_helper"

class SolidQueue::JobTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.destroy_all
    JobResult.delete_all
  end

  class NonOverlappingJob < ApplicationJob
    limits_concurrency key: ->(job_result, **) { job_result }

    def perform(job_result)
    end
  end

  class NonOverlappingGroupedJob1 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "MyGroup"
  end

  class NonOverlappingGroupedJob2 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "MyGroup"
  end

  setup do
    @result = JobResult.create!(queue_name: "default")
  end

  test "enqueue active job to be executed right away" do
    active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")

    assert_ready do
      SolidQueue::Job.enqueue_active_job(active_job)
    end

    solid_queue_job = SolidQueue::Job.last
    assert_equal 8, solid_queue_job.priority
    assert_equal "test", solid_queue_job.queue_name
    assert_equal "AddToBufferJob", solid_queue_job.class_name
    assert Time.now >= solid_queue_job.scheduled_at
    assert_equal [ 1 ], solid_queue_job.arguments["arguments"]

    execution = SolidQueue::ReadyExecution.last
    assert_equal solid_queue_job, execution.job
    assert_equal "test", execution.queue_name
    assert_equal 8, execution.priority
  end

  test "enqueue active job to be scheduled in the future" do
    active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")

    assert_scheduled do
      SolidQueue::Job.enqueue_active_job(active_job, scheduled_at: 5.minutes.from_now)
    end

    solid_queue_job = SolidQueue::Job.last
    assert_equal 8, solid_queue_job.priority
    assert_equal "test", solid_queue_job.queue_name
    assert_equal "AddToBufferJob", solid_queue_job.class_name
    assert Time.now < solid_queue_job.scheduled_at
    assert_equal [ 1 ], solid_queue_job.arguments["arguments"]

    execution = SolidQueue::ScheduledExecution.last
    assert_equal solid_queue_job, execution.job
    assert_equal "test", execution.queue_name
    assert_equal 8, execution.priority
    assert Time.now < execution.scheduled_at
  end

  test "enqueue jobs without concurrency controls" do
    active_job = AddToBufferJob.perform_later(1)
    assert_nil active_job.concurrency_limit
    assert_nil active_job.concurrency_key

    job = SolidQueue::Job.last
    assert_nil job.concurrency_limit
    assert_not job.concurrency_limited?
  end

  test "enqueue jobs with concurrency controls" do
    active_job = NonOverlappingJob.perform_later(@result, name: "A")
    assert_equal 1, active_job.concurrency_limit
    assert_equal "SolidQueue::JobTest::NonOverlappingJob/JobResult/#{@result.id}", active_job.concurrency_key

    job = SolidQueue::Job.last
    assert_equal active_job.concurrency_limit, job.concurrency_limit
    assert_equal active_job.concurrency_key, job.concurrency_key
  end

  test "enqueue jobs with concurrency controls in the same concurrency group" do
    assert_ready do
      active_job = NonOverlappingGroupedJob1.perform_later(@result, name: "A")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "MyGroup/JobResult/#{@result.id}", active_job.concurrency_key
    end

    assert_blocked do
      active_job = NonOverlappingGroupedJob2.perform_later(@result, name: "B")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "MyGroup/JobResult/#{@result.id}", active_job.concurrency_key
    end
  end

  test "block jobs when concurrency limits are reached" do
    assert_ready do
      NonOverlappingJob.perform_later(@result, name: "A")
    end

    assert_blocked do
      NonOverlappingJob.perform_later(@result, name: "B")
    end

    blocked_execution = SolidQueue::BlockedExecution.last
    assert blocked_execution.expires_at <= SolidQueue.default_concurrency_control_period.from_now
  end

  if ENV["SEPARATE_CONNECTION"] && ENV["TARGET_DB"] != "sqlite"
    test "uses a different connection and transaction than the one in use when connects_to is specified" do
      assert_difference -> { SolidQueue::Job.count } do
        assert_no_difference -> { JobResult.count } do
          JobResult.transaction do
            JobResult.create!(queue_name: "default", value: "this will be rolled back")
            StoreResultJob.perform_later("enqueued inside a rolled back transaction")
            raise ActiveRecord::Rollback
          end
        end
      end

      job = SolidQueue::Job.last
      assert_equal "enqueued inside a rolled back transaction", job.arguments.dig("arguments", 0)
    end
  end

  private
    def assert_ready(&block)
      assert_difference -> { SolidQueue::Job.count } => +1, -> { SolidQueue::ReadyExecution.count } => +1, &block
    end

    def assert_scheduled(&block)
      assert_no_difference -> { SolidQueue::ReadyExecution.count } do
        assert_difference -> { SolidQueue::Job.count } => +1, -> { SolidQueue::ScheduledExecution.count } => +1, &block
      end
    end

    def assert_blocked(&block)
      assert_no_difference -> { SolidQueue::ReadyExecution.count } do
        assert_difference -> { SolidQueue::Job.count } => +1, -> { SolidQueue::BlockedExecution.count } => +1, &block
      end
    end
end
