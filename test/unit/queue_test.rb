require "test_helper"

class QueueTest < ActiveSupport::TestCase
  setup do
    freeze_time

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

  test "return latency in seconds on each queue" do
    travel_to 5.minutes.from_now

    assert_in_delta 5.minutes.to_i, @background_queue.latency, 1.second.to_i
    assert_equal 0, @default_queue.latency

    @background_queue = SolidQueue::Queue.find_by_name("background")
    @default_queue = SolidQueue::Queue.find_by_name("default")
    travel_to 10.minutes.from_now

    assert_in_delta 15.minutes.to_i, @background_queue.latency, 1.second.to_i
    assert_equal 0, @default_queue.latency
  end

  test "returns memoized latency after the first call" do
    travel_to 5.minutes.from_now

    assert_in_delta 5.minutes.to_i, @background_queue.latency, 1.second.to_i

    travel_to 10.minutes.from_now

    assert_in_delta 5.minutes.to_i, @background_queue.latency, 1.second.to_i
  end

  test "return human latency on each queue" do
    travel_to 5.minutes.from_now

    assert_match (/5 minutes/), @background_queue.human_latency
    assert_match (/0 seconds/), @default_queue.human_latency
  end
end
