# frozen_string_literal: true
require "test_helper"

class QueuingTest < ActiveSupport::TestCase
  setup do
    @dispatcher = SolidQueue::Dispatcher.new(queues: [ "default", "background" ], worker_count: 3)
    @dispatcher.start
  end

  teardown do
    @dispatcher.stop
    JobBuffer.clear
  end

  test "enqueue and run jobs" do
    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal [ "hey", "ho" ], JobBuffer.values.sort
  end

  test "enqueue and handle retries" do
    RaisingJob.perform_later "DefaultsError", 3

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal 3, JobBuffer.size
    assert_equal "Successfully completed job", JobBuffer.last_value

    assert_equal 0, SolidQueue::FailedExecution.count

    JobBuffer.clear
    RaisingJob.perform_later "DefaultsError", 10

    wait_for_jobs_to_finish_for(10.seconds)

    assert_equal 5, JobBuffer.size
    assert_not_includes JobBuffer, "Successfully completed job"
    assert_equal 1, SolidQueue::FailedExecution.count
    failed_execution = SolidQueue::FailedExecution.last
    assert_match /\ADefaultsError\s+This is a DefaultsError exception/, failed_execution.error
    assert_equal "RaisingJob", failed_execution.job.arguments["job_class"]
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
