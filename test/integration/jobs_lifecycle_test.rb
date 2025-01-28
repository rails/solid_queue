# frozen_string_literal: true

require "test_helper"

class JobsLifecycleTest < ActiveSupport::TestCase
  setup do
    @_on_thread_error = SolidQueue.on_thread_error
    SolidQueue.on_thread_error = silent_on_thread_error_for([ ExpectedTestError, RaisingJob::DefaultError ], @_on_thread_error)
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3)
    @dispatcher = SolidQueue::Dispatcher.new(batch_size: 10, polling_interval: 0.2)
  end

  teardown do
    SolidQueue.on_thread_error = @_on_thread_error
    @worker.stop
    @dispatcher.stop

    JobBuffer.clear
  end

  test "enqueue and run jobs" do
    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal [ "hey", "ho" ], JobBuffer.values.sort
    assert_equal 2, SolidQueue::Job.finished.count
  end

  test "enqueue and run jobs that fail without retries" do
    RaisingJob.perform_later(ExpectedTestError, "A")
    RaisingJob.perform_later(ExpectedTestError, "B")
    jobs = SolidQueue::Job.last(2)

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(3.seconds)

    message = "raised ExpectedTestError for the 1st time"
    assert_equal [ "A: #{message}", "B: #{message}" ], JobBuffer.values.sort

    assert_empty SolidQueue::Job.finished
  end

  test "enqueue and run jobs that fail and succeed after retrying" do
    RaisingJob.perform_later(RaisingJob::DefaultError, "A", 5) # this will fail after being retried
    RaisingJob.perform_later(RaisingJob::DefaultError, "B")

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(3.seconds)

    messages_from_a = 1.upto(3).collect { |i| "A: raised RaisingJob::DefaultError for the #{i.ordinalize} time" }
    messages_from_b = [ "B: raised RaisingJob::DefaultError for the 1st time", "Successfully completed job" ]

    assert_equal messages_from_a + messages_from_b, JobBuffer.values.sort

    assert_equal 4, SolidQueue::Job.finished.count # B + its retry + 2 retries of A
    assert_equal 1, SolidQueue::FailedExecution.count
  end

  test "retry job that failed after being automatically retried" do
    RaisingJob.perform_later(RaisingJob::DefaultError, "A", 5)

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(3.seconds)

    assert_equal 2, SolidQueue::Job.finished.count # 2 retries of A
    assert_equal 1, SolidQueue::FailedExecution.count

    failed_execution = SolidQueue::FailedExecution.last
    failed_execution.job.retry

    wait_for_jobs_to_finish_for(3.seconds)

    assert_equal 4, SolidQueue::Job.finished.count # Add other 2 retries of A
    assert_equal 1, SolidQueue::FailedExecution.count
  end

  test "enqueue and run jobs that fail and it's discarded" do
    RaisingJob.perform_later(RaisingJob::DiscardableError, "A")

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(1.seconds)

    assert_equal [ "A: raised RaisingJob::DiscardableError for the 1st time" ], JobBuffer.values.sort

    assert_equal 1, SolidQueue::Job.finished.count
    assert_equal 0, SolidQueue::FailedExecution.count
  end

  test "schedule and run jobs" do
    AddToBufferJob.set(wait: 1.day).perform_later("I'm scheduled")
    AddToBufferJob.set(wait: 3.days).perform_later("I'm scheduled later")

    @dispatcher.start
    @worker.start

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
      @worker.start

      wait_for_jobs_to_finish_for(2.seconds)
    end

    assert_equal 0, SolidQueue::Job.count
  end

  test "clear finished jobs after configured period" do
    10.times { AddToBufferJob.perform_later(2) }
    jobs = SolidQueue::Job.last(10)

    assert_no_difference -> { SolidQueue::Job.count } do
      SolidQueue::Job.clear_finished_in_batches
    end

    # Simulate that only 5 of these jobs finished
    jobs.sample(5).each(&:finished!)

    assert_no_difference -> { SolidQueue::Job.count } do
      SolidQueue::Job.clear_finished_in_batches
    end

    travel_to 3.days.from_now

    assert_difference -> { SolidQueue::Job.count }, -5 do
      SolidQueue::Job.clear_finished_in_batches
    end
  end

  test "respect class name when clearing finished jobs" do
    10.times { AddToBufferJob.perform_later(2) }
    10.times { RaisingJob.perform_later(RuntimeError, "A") }
    jobs = SolidQueue::Job.all

    jobs.each(&:finished!)

    travel_to 3.days.from_now

    SolidQueue::Job.clear_finished_in_batches(class_name: "AddToBufferJob")

    assert_equal 0, SolidQueue::Job.where(class_name: "AddToBufferJob").count
    assert_equal 10, SolidQueue::Job.where(class_name: "RaisingJob").count
  end

  private
    def deleting_finished_jobs
      previous, SolidQueue.preserve_finished_jobs = SolidQueue.preserve_finished_jobs, false
      yield
    ensure
      SolidQueue.preserve_finished_jobs = previous
    end
end
