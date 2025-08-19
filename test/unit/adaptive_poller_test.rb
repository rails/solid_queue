require "test_helper"

class AdaptivePollerTest < ActiveSupport::TestCase
  setup do
    @poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)
  end

  test "initializes with correct default values" do
    assert_equal 0.1, @poller.instance_variable_get(:@base_interval)
    assert_equal 0.1, @poller.instance_variable_get(:@current_interval)
    assert_equal 0, @poller.instance_variable_get(:@consecutive_empty_polls)
    assert_equal 0, @poller.instance_variable_get(:@consecutive_busy_polls)
  end

  test "next_interval accelerates when system is busy" do
    initial_interval = @poller.current_interval

    15.times do
      @poller.next_interval([ 1, 2, 3 ])
      sleep(0.01)
    end

    new_interval = @poller.current_interval
    assert new_interval < initial_interval, "Interval should decrease when system is busy (#{initial_interval} -> #{new_interval})"
  end

  test "next_interval decelerates when system is idle" do
    initial_interval = @poller.current_interval

    8.times do
      @poller.next_interval([])
      sleep(0.01)
    end

    new_interval = @poller.current_interval
    assert new_interval > initial_interval, "Interval should increase when system is idle (#{initial_interval} -> #{new_interval})"
  end

  test "respects minimum interval limits" do
    SolidQueue.adaptive_polling_min_interval = 0.05

    10.times do
      @poller.next_interval([ 1, 2, 3, 4, 5 ])
    end

    current_interval = @poller.current_interval
    assert current_interval >= SolidQueue.adaptive_polling_min_interval,
           "Interval should not go below minimum"
  ensure
    SolidQueue.adaptive_polling_min_interval = 0.05 # Reset to default
  end

  test "respects maximum interval limits" do
    SolidQueue.adaptive_polling_max_interval = 2.0

    20.times do
      @poller.next_interval([])
    end

    current_interval = @poller.current_interval
    assert current_interval <= SolidQueue.adaptive_polling_max_interval,
           "Interval should not exceed maximum"
  ensure
    SolidQueue.adaptive_polling_max_interval = 5.0 # Reset to default
  end

  test "handles different job count scenarios correctly" do
    interval1 = @poller.next_interval({ job_count: 3, execution_time: 0.1 })

    interval2 = @poller.next_interval([ 1, 2 ])

    interval3 = @poller.next_interval(1)

    [ interval1, interval2, interval3 ].each do |interval|
      assert interval.is_a?(Numeric), "Should return numeric interval"
      assert interval > 0, "Interval should be positive"
    end
  end

  test "reset clears statistics and returns to base interval" do
    5.times { @poller.next_interval([ 1, 2, 3 ]) }

    @poller.reset!

    assert_equal 0, @poller.instance_variable_get(:@consecutive_empty_polls)
    assert_equal 0, @poller.instance_variable_get(:@consecutive_busy_polls)
    assert_equal 0.1, @poller.instance_variable_get(:@current_interval)
  end

  test "system_is_busy detection works correctly" do
    assert_not @poller.send(:system_is_busy?)

    5.times { @poller.next_interval([ 1, 2, 3 ]) }

    assert @poller.send(:system_is_busy?), "Should detect busy system"
  end

  test "system_is_idle detection works correctly" do
    assert_not @poller.send(:system_is_idle?)

    6.times { @poller.next_interval([]) }

    assert @poller.send(:system_is_idle?), "Should detect idle system"
  end

  test "circular buffer maintains correct size" do
    buffer = SolidQueue::CircularBuffer.new(3)

    5.times { |i| buffer.push({ value: i }) }

    assert_equal 3, buffer.size
    recent = buffer.recent(2)
    assert_equal 2, recent.size
  end

  test "circular buffer recent method works correctly" do
    buffer = SolidQueue::CircularBuffer.new(5)

    (1..3).each { |i| buffer.push({ value: i }) }

    recent = buffer.recent(2)
    assert_equal [ { value: 2 }, { value: 3 } ], recent

    all_recent = buffer.recent(10)
    assert_equal 3, all_recent.size
  end

  test "adaptation factors from configuration are used" do
    original_speedup = SolidQueue.adaptive_polling_speedup_factor
    original_backoff = SolidQueue.adaptive_polling_backoff_factor

    SolidQueue.adaptive_polling_speedup_factor = 0.5
    SolidQueue.adaptive_polling_backoff_factor = 2.0

    initial_interval = @poller.instance_variable_get(:@current_interval)

    @poller.instance_variable_set(:@consecutive_busy_polls, 1)
    accelerated = @poller.send(:accelerate_polling)
    expected_accelerated = initial_interval * 0.5
    assert_in_delta expected_accelerated, accelerated, 0.001

    @poller.instance_variable_set(:@consecutive_empty_polls, 1)
    decelerated = @poller.send(:decelerate_polling)
    expected_decelerated = initial_interval * 2.0 * 1.1 # backoff_factor * multiplier
    assert_in_delta expected_decelerated, decelerated, 0.001

  ensure
    SolidQueue.adaptive_polling_speedup_factor = original_speedup
    SolidQueue.adaptive_polling_backoff_factor = original_backoff
  end

  test "maintains current interval when system is stable" do
    @poller.instance_variable_set(:@current_interval, 0.15)

    @poller.instance_variable_set(:@consecutive_empty_polls, 2)
    @poller.instance_variable_set(:@consecutive_busy_polls, 0)

    3.times { @poller.next_interval([ 1 ]) }      # Some work
    2.times { @poller.next_interval([]) }

    current = @poller.instance_variable_get(:@current_interval)
    expected_convergence = @poller.send(:maintain_current_interval)

    assert expected_convergence < 0.15, "Should converge towards base interval"
  end
end
