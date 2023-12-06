# frozen_string_literal: true
require "test_helper"

class JobsLifecycleTest < ActiveSupport::TestCase
  setup do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.5)
    @scheduler = SolidQueue::Scheduler.new(batch_size: 10, polling_interval: 1)
  end

  teardown do
    @worker.stop
    @scheduler.stop

    JobBuffer.clear
  end

  test "enqueue and run jobs" do
    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    @scheduler.start(mode: :async)
    @worker.start(mode: :async)

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal [ "hey", "ho" ], JobBuffer.values.sort
    assert_equal 2, SolidQueue::Job.finished.count
  end

  test "schedule and run jobs" do
    AddToBufferJob.set(wait: 1.day).perform_later("I'm scheduled")
    AddToBufferJob.set(wait: 3.days).perform_later("I'm scheduled later")

    @scheduler.start(mode: :async)
    @worker.start(mode: :async)

    assert_equal 2, SolidQueue::ScheduledExecution.count

    travel_to 2.days.from_now

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal 1, JobBuffer.size
    assert_equal "I'm scheduled", JobBuffer.last_value

    travel_to 5.days.from_now

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal 2, JobBuffer.size
    assert_equal "I'm scheduled later", JobBuffer.last_value

    assert_equal 2, SolidQueue::Job.finished.count
  end

  test "delete finished jobs after they run" do
    deleting_finished_jobs do
      AddToBufferJob.perform_later "hey"
      @worker.start(mode: :async)

      wait_for_jobs_to_finish_for(2.seconds)
    end

    assert_equal 0, SolidQueue::Job.count
  end

  private
    def deleting_finished_jobs
      previous, SolidQueue.preserve_finished_jobs = SolidQueue.preserve_finished_jobs, false
      yield
    ensure
      SolidQueue.preserve_finished_jobs = previous
    end
end
