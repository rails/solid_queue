require "test_helper"

class SolidQueue::JobTest < ActiveSupport::TestCase
  test "enqueue active job to be executed right away" do
    active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")

    assert_difference -> { SolidQueue::Job.count } => +1, -> { SolidQueue::ReadyExecution.count } => +1 do
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

    assert_difference -> { SolidQueue::Job.count } => +1, -> { SolidQueue::ScheduledExecution.count } => +1 do
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
end
