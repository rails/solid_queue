require "test_helper"

class EnhancementTest < ActiveSupport::TestCase
  setup do
    @original_enabled = SolidQueue.adaptive_polling_enabled
    @original_min = SolidQueue.adaptive_polling_min_interval
    @original_max = SolidQueue.adaptive_polling_max_interval
    @original_backoff = SolidQueue.adaptive_polling_backoff_factor
    @original_speedup = SolidQueue.adaptive_polling_speedup_factor
    @original_window = SolidQueue.adaptive_polling_window_size

    SolidQueue.adaptive_polling_min_interval = 0.05
    SolidQueue.adaptive_polling_max_interval = 5.0
    SolidQueue.adaptive_polling_backoff_factor = 1.5
    SolidQueue.adaptive_polling_speedup_factor = 0.7
    SolidQueue.adaptive_polling_window_size = 10
  end

  teardown do
    @worker&.stop
    SolidQueue.adaptive_polling_enabled = @original_enabled
    SolidQueue.adaptive_polling_min_interval = @original_min
    SolidQueue.adaptive_polling_max_interval = @original_max
    SolidQueue.adaptive_polling_backoff_factor = @original_backoff
    SolidQueue.adaptive_polling_speedup_factor = @original_speedup
    SolidQueue.adaptive_polling_window_size = @original_window
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

    empty_result = []
    busy_result = [ mock_execution, mock_execution ]

    @worker.expects(:claim_executions).returns(empty_result).times(10)
    @worker.pool.expects(:post).never

    intervals = []
    10.times do
      intervals << @worker.send(:poll)
      sleep(0.01)
    end

    assert intervals.last > intervals.first, "Interval should increase with empty polls (#{intervals.first} -> #{intervals.last})"

    @worker.expects(:claim_executions).returns(busy_result).times(10)
    @worker.pool.expects(:post).with(anything).times(20)

    10.times { intervals << @worker.send(:poll) }

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

    @worker.expects(:claim_executions).returns([]).times(3)
    @worker.expects(:claim_executions).returns([ mock_execution ]).times(2)
    @worker.pool.expects(:post).with(anything).times(2)

    5.times { @worker.send(:poll) }

    stats = @worker.instance_variable_get(:@polling_stats)
    assert_equal 5, stats[:total_polls]
    assert_equal 2, stats[:total_jobs_claimed]
    assert_equal 3, stats[:empty_polls]
  end

  test "statistics logging works periodically" do
    SolidQueue.adaptive_polling_enabled = true

    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    logger_mock.expects(:info).with(regexp_matches(/initialized with adaptive polling enabled/))

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    stats = @worker.instance_variable_get(:@polling_stats)
    stats[:total_polls] = 1000
    stats[:total_jobs_claimed] = 500
    stats[:empty_polls] = 500

    logger_mock.expects(:info).with(regexp_matches(/adaptive polling stats/))

    assert @worker.send(:should_log_stats?), "Should log stats at 1000 polls"

    @worker.send(:log_polling_stats)
  end

  test "statistics reset works correctly" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

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

    @worker.expects(:claim_executions).returns([]).times(6)
    6.times { @worker.send(:poll) }

    poller = @worker.adaptive_poller
    assert poller.instance_variable_get(:@consecutive_empty_polls) > 0

    @worker.send(:reset_polling_stats!)

    assert_equal 0, poller.instance_variable_get(:@consecutive_empty_polls)
  end

  test "worker logs initialization with adaptive polling" do
    SolidQueue.adaptive_polling_enabled = true

    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    logger_mock.expects(:info).with(regexp_matches(/initialized with adaptive polling enabled/))

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
  end

  test "worker initialization fails with invalid min_interval" do
    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_min_interval = -0.1

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "worker initialization fails with inconsistent intervals" do
    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_min_interval = 5.0
    SolidQueue.adaptive_polling_max_interval = 1.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InconsistentConfigurationError do
      SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

    assert_match(/adaptive_polling_min_interval.*must be less than.*adaptive_polling_max_interval/, error.message)
  end

  test "worker initialization logs configuration error and re-raises" do
    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_backoff_factor = 0.5

    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    logger_mock.expects(:error).with(regexp_matches(/Adaptive Polling configuration error/))

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

    assert_match(/adaptive_polling_backoff_factor.*must be greater than 1.0/, error.message)
  end

  test "worker initialization includes configuration summary in log" do
    SolidQueue.adaptive_polling_enabled = true

    logger_mock = mock("logger")
    SolidQueue.stubs(:logger).returns(logger_mock)

    logger_mock.expects(:info).with(regexp_matches(/initialized with adaptive polling enabled.*enabled.*true/))

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
  end

  test "time-based statistics logging works" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    stats = @worker.instance_variable_get(:@polling_stats)
    stats[:last_reset] = Time.current - 301

    assert @worker.send(:should_log_stats?), "Should log stats after 5 minutes"
  end

  test "interval calculation uses execution time in poll result" do
    SolidQueue.adaptive_polling_enabled = true

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    @worker.expects(:claim_executions).returns([ mock_execution ])
    @worker.pool.expects(:post).once

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
