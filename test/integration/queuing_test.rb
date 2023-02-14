# frozen_string_literal: true
require "test_helper"

class QueuingTest < ActiveSupport::TestCase
  setup do
    @dispatcher = SolidQueue::Dispatcher.new(queue_name: "background", worker_count: 3, polling_interval: 1)
    @dispatcher.start

    @scheduler = SolidQueue::Scheduler.new(batch_size: 10, polling_interval: 1)
    @scheduler.start
  end

  teardown do
    @dispatcher.stop
    @scheduler.stop

    JobBuffer.clear
  end

  test "enqueue and run jobs" do
    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal [ "hey", "ho" ], JobBuffer.values.sort
  end

  test "schedule and run jobs" do
    AddToBufferJob.set(wait: 1.day).perform_later("I'm scheduled")
    AddToBufferJob.set(wait: 3.days).perform_later("I'm scheduled later")

    assert_equal 2, SolidQueue::ScheduledExecution.count

    travel_to 2.days.from_now

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal 1, JobBuffer.size
    assert_equal "I'm scheduled", JobBuffer.last_value

    travel_to 5.days.from_now

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal 2, JobBuffer.size
    assert_equal "I'm scheduled later", JobBuffer.last_value
  end

  private
    def wait_for_jobs_to_finish_for(timeout = 10.seconds)
      Timeout.timeout(timeout) do
        while SolidQueue::Job.where(finished_at: nil).any? do
          sleep 0.25
        end
      end
    rescue Timeout::Error
    end
end
