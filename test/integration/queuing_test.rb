# frozen_string_literal: true
require "test_helper"

class QueuingTest < ActiveSupport::TestCase
  test "enqueue and run jobs" do
    dispatcher = SolidQueue::Dispatcher.new(queues: [ "default", "background" ], worker_count: 3)
    dispatcher.start

    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    wait_for_jobs_to_finish_for(5.seconds)

    dispatcher.stop
    assert_equal JobBuffer.values.sort, [ "hey", "ho" ]
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
