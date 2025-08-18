require "test_helper"

class AdaptivePollingEnhancementTest < ActiveSupport::TestCase
  setup do
    @original_enabled = SolidQueue.adaptive_polling_enabled
    @original_min = SolidQueue.adaptive_polling_min_interval
    @original_max = SolidQueue.adaptive_polling_max_interval
  end

  teardown do
    @worker&.stop
    SolidQueue.adaptive_polling_enabled = @original_enabled
    SolidQueue.adaptive_polling_min_interval = @original_min
    SolidQueue.adaptive_polling_max_interval = @original_max
    JobBuffer.clear
  end

  test "worker initializes with adaptive polling when enabled" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    assert_not_nil @worker.adaptive_poller, "Should have adaptive poller when enabled"
    assert_respond_to @worker.adaptive_poller, :next_interval
  end

  test "worker initializes without adaptive polling when disabled" do
    SolidQueue.adaptive_polling_enabled = false

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    assert_nil @worker.adaptive_poller, "Should not have adaptive poller when disabled"
  end

  test "adaptive polling changes interval based on workload" do
    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_min_interval = 0.01
    SolidQueue.adaptive_polling_max_interval = 1.0

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Mock claim_executions to return different results
    empty_result = []
    busy_result = [ mock_execution, mock_execution ]

    @worker.expects(:claim_executions).returns(empty_result).times(10) # Need more for idle detection
    @worker.pool.expects(:post).never

    # Simulate multiple empty polls - should increase interval
    intervals = []
    10.times do
      intervals << @worker.send(:poll)
      sleep(0.01) # Small delay to allow time-based adjustments
    end

    # With 10 empty polls, should trigger idle state (needs >= 5)
    assert intervals.last > intervals.first, "Interval should increase with empty polls (#{intervals.first} -> #{intervals.last})"

    # Now simulate busy system
    @worker.expects(:claim_executions).returns(busy_result).times(10) # More polls for busy detection
    @worker.pool.expects(:post).with(anything).times(20) # 2 executions * 10 polls

    10.times { intervals << @worker.send(:poll) }

    # Should decrease after consistent busy polls
    assert intervals.last < intervals[-11], "Interval should decrease with busy polls (#{intervals[-11]} -> #{intervals.last})"
  end

  test "fallback to original behavior when adaptive polling disabled" do
    SolidQueue.adaptive_polling_enabled = false

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    empty_result = []
    @worker.expects(:claim_executions).returns(empty_result)
    @worker.pool.expects(:idle?).returns(true)

    interval = @worker.send(:poll)
    assert_equal 0.1, interval, "Should use original polling interval when disabled"
  end

  test "polling statistics are tracked correctly" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Mock some polls
    @worker.expects(:claim_executions).returns([]).times(3)                     # 3 empty polls
    @worker.expects(:claim_executions).returns([ mock_execution ]).times(2)       # 2 busy polls
    @worker.pool.expects(:post).with(anything).times(2)

    5.times { @worker.send(:poll) }

    stats = @worker.instance_variable_get(:@polling_stats)
    assert_equal 5, stats[:total_polls]
    assert_equal 2, stats[:total_jobs_claimed]
    assert_equal 3, stats[:empty_polls]
  end

  test "statistics logging works periodically" do
    SolidQueue.adaptive_polling_enabled = true

    # Set up a mock logger
    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    # Allow initialization logging
    logger_mock.expects(:info).with(regexp_matches(/initialized with adaptive polling enabled/))

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Set up stats to trigger logging
    stats = @worker.instance_variable_get(:@polling_stats)
    stats[:total_polls] = 1000 # Should trigger logging
    stats[:total_jobs_claimed] = 500
    stats[:empty_polls] = 500

    # Mock the logging
    logger_mock.expects(:info).with(regexp_matches(/adaptive polling stats/))

    assert @worker.send(:should_log_stats?), "Should log stats at 1000 polls"

    @worker.send(:log_polling_stats)
  end

  test "statistics reset works correctly" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Set some stats
    stats = @worker.instance_variable_get(:@polling_stats)
    stats[:total_polls] = 100
    stats[:total_jobs_claimed] = 50
    stats[:empty_polls] = 50

    @worker.send(:reset_polling_stats!)

    new_stats = @worker.instance_variable_get(:@polling_stats)
    assert_equal 0, new_stats[:total_polls]
    assert_equal 0, new_stats[:total_jobs_claimed]
    assert_equal 0, new_stats[:empty_polls]
  end

  test "class method adaptive_polling_enabled? reflects configuration" do
    SolidQueue.adaptive_polling_enabled = true
    assert SolidQueue::Worker.adaptive_polling_enabled?

    SolidQueue.adaptive_polling_enabled = false
    assert_not SolidQueue::Worker.adaptive_polling_enabled?
  end

  test "adaptive poller is reset when statistics are reset" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Make some polls to change adaptive poller state
    @worker.expects(:claim_executions).returns([]).times(6)
    6.times { @worker.send(:poll) }

    # Verify adaptive poller has some state
    poller = @worker.adaptive_poller
    assert poller.instance_variable_get(:@consecutive_empty_polls) > 0

    # Reset should clear adaptive poller state too
    @worker.send(:reset_polling_stats!)

    assert_equal 0, poller.instance_variable_get(:@consecutive_empty_polls)
  end

  test "worker logs initialization with adaptive polling" do
    SolidQueue.adaptive_polling_enabled = true

    # Set up a mock logger
    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    logger_mock.expects(:info).with(regexp_matches(/initialized with adaptive polling enabled/))

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
  end

  test "time-based statistics logging works" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Set last_reset to trigger time-based logging
    stats = @worker.instance_variable_get(:@polling_stats)
    stats[:last_reset] = Time.current - 301 # More than 5 minutes ago

    assert @worker.send(:should_log_stats?), "Should log stats after 5 minutes"
  end

  test "interval calculation uses execution time in poll result" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    # Mock claim_executions to simulate different execution times
    @worker.expects(:claim_executions).returns([ mock_execution ])
    @worker.pool.expects(:post).once

    # The poll method should track execution time
    interval = @worker.send(:poll)

    assert interval.is_a?(Numeric), "Should return numeric interval"
    assert interval > 0, "Interval should be positive"
  end

  private

  def mock_execution
    execution = mock("execution")
    execution
  end
end
