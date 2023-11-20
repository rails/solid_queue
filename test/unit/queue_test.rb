require "test_helper"

class QueueTest < ActiveSupport::TestCase
  setup do
    5.times do
      AddToBufferJob.perform_later "hey!"
    end

    @background_queue = SolidQueue::Queue.find_by_name("background")
    @default_queue = SolidQueue::Queue.find_by_name("default")
  end

  test "count jobs currently in a queue" do
    assert_equal 5, @background_queue.size
    assert_equal 0, @default_queue.size
  end

  test "clear queue" do
    assert_difference [ -> { SolidQueue::Job.count }, -> { SolidQueue::ReadyExecution.count } ], -5 do
      @background_queue.clear
    end
    assert_equal 0, @background_queue.size

    assert_no_difference [ -> { SolidQueue::Job.count }, -> { SolidQueue::ReadyExecution.count } ] do
      @default_queue.clear
    end
  end

  test "all existing queues" do
    assert_equal [ @background_queue ], SolidQueue::Queue.all
  end

  test "pause and resume queue" do
    assert_changes -> { @default_queue.paused? }, from: false, to: true do
      @default_queue.pause
    end

    assert_changes -> { @default_queue.paused? }, from: true, to: false do
      @default_queue.resume
    end
  end
end
