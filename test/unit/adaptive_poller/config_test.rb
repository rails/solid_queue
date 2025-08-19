require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  setup do
    @original_enabled = SolidQueue.adaptive_polling_enabled
    @original_min = SolidQueue.adaptive_polling_min_interval
    @original_max = SolidQueue.adaptive_polling_max_interval
    @original_backoff = SolidQueue.adaptive_polling_backoff_factor
    @original_speedup = SolidQueue.adaptive_polling_speedup_factor
    @original_window = SolidQueue.adaptive_polling_window_size

    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_min_interval = 0.05
    SolidQueue.adaptive_polling_max_interval = 5.0
    SolidQueue.adaptive_polling_backoff_factor = 1.5
    SolidQueue.adaptive_polling_speedup_factor = 0.7
    SolidQueue.adaptive_polling_window_size = 10
  end

  teardown do
    SolidQueue.adaptive_polling_enabled = @original_enabled
    SolidQueue.adaptive_polling_min_interval = @original_min
    SolidQueue.adaptive_polling_max_interval = @original_max
    SolidQueue.adaptive_polling_backoff_factor = @original_backoff
    SolidQueue.adaptive_polling_speedup_factor = @original_speedup
    SolidQueue.adaptive_polling_window_size = @original_window
  end

  test "validation passes with valid configuration" do
    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation skips when adaptive polling is disabled" do
    SolidQueue.adaptive_polling_enabled = false
    SolidQueue.adaptive_polling_min_interval = -1

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "invalid min_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_min_interval = 0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "negative min_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_min_interval = -0.1

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "non-numeric min_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_min_interval = "0.1"

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "too small min_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_min_interval = 0.0005

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval.*is too small/, error.message)
  end

  test "invalid max_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_max_interval = -1

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_max_interval must be a positive number/, error.message)
  end

  test "too large max_interval raises InvalidIntervalError" do
    SolidQueue.adaptive_polling_max_interval = 500

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_max_interval.*is too large/, error.message)
  end

  test "min_interval >= max_interval raises InconsistentConfigurationError" do
    SolidQueue.adaptive_polling_min_interval = 5.0
    SolidQueue.adaptive_polling_max_interval = 5.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InconsistentConfigurationError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval.*must be less than.*adaptive_polling_max_interval/, error.message)
  end

  test "backoff_factor <= 1.0 raises InvalidFactorError" do
    SolidQueue.adaptive_polling_backoff_factor = 1.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_backoff_factor.*must be greater than 1.0/, error.message)
  end

  test "negative backoff_factor raises InvalidFactorError" do
    SolidQueue.adaptive_polling_backoff_factor = -0.5

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_backoff_factor must be a positive number/, error.message)
  end

  test "too large backoff_factor raises InvalidFactorError" do
    SolidQueue.adaptive_polling_backoff_factor = 6.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_backoff_factor.*is too large/, error.message)
  end

  test "speedup_factor >= 1.0 raises InvalidFactorError" do
    SolidQueue.adaptive_polling_speedup_factor = 1.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_speedup_factor.*must be less than 1.0/, error.message)
  end

  test "negative speedup_factor raises InvalidFactorError" do
    SolidQueue.adaptive_polling_speedup_factor = -0.1

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_speedup_factor must be a positive number/, error.message)
  end

  test "too small speedup_factor raises InvalidFactorError" do
    SolidQueue.adaptive_polling_speedup_factor = 0.05

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_speedup_factor.*is too small/, error.message)
  end

  test "zero window_size raises InvalidWindowSizeError" do
    SolidQueue.adaptive_polling_window_size = 0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size must be a positive integer/, error.message)
  end

  test "negative window_size raises InvalidWindowSizeError" do
    SolidQueue.adaptive_polling_window_size = -5

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size must be a positive integer/, error.message)
  end

  test "float window_size raises InvalidWindowSizeError" do
    SolidQueue.adaptive_polling_window_size = 5.5

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size must be a positive integer/, error.message)
  end

  test "too small window_size raises InvalidWindowSizeError" do
    SolidQueue.adaptive_polling_window_size = 2

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size.*is too small/, error.message)
  end

  test "too large window_size raises InvalidWindowSizeError" do
    SolidQueue.adaptive_polling_window_size = 1500

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size.*is too large/, error.message)
  end

  test "interval ratio too small raises InconsistentConfigurationError" do
    SolidQueue.adaptive_polling_min_interval = 1.0
    SolidQueue.adaptive_polling_max_interval = 1.5

    error = assert_raises SolidQueue::AdaptivePoller::Config::InconsistentConfigurationError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/ratio between max_interval.*and min_interval.*is too small/, error.message)
  end

  test "interval ratio too large raises InconsistentConfigurationError" do
    SolidQueue.adaptive_polling_min_interval = 0.001
    SolidQueue.adaptive_polling_max_interval = 2.0

    error = assert_raises SolidQueue::AdaptivePoller::Config::InconsistentConfigurationError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/ratio between max_interval.*and min_interval.*is very large/, error.message)
  end

  test "configuration_summary returns proper format when enabled" do
    summary = SolidQueue::AdaptivePoller::Config.configuration_summary

    assert_equal true, summary[:enabled]
    assert_equal "0.05s", summary[:min_interval]
    assert_equal "5.0s", summary[:max_interval]
    assert_equal 1.5, summary[:backoff_factor]
    assert_equal 0.7, summary[:speedup_factor]
    assert_equal 10, summary[:window_size]
    assert_equal 100.0, summary[:interval_ratio]
  end

  test "configuration_summary returns disabled message when disabled" do
    SolidQueue.adaptive_polling_enabled = false

    summary = SolidQueue::AdaptivePoller::Config.configuration_summary

    assert_equal "Adaptive Polling: DISABLED", summary
  end

  test "worker initialization fails with invalid configuration" do
    SolidQueue.adaptive_polling_min_interval = -0.1

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "worker initialization succeeds with valid configuration" do
    worker = nil

    assert_nothing_raised do
      worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

    assert_not_nil worker.adaptive_poller
  ensure
    worker&.stop
  end

  test "multiple validation calls with same configuration" do
    5.times do
      assert_nothing_raised do
        SolidQueue::AdaptivePoller::Config.validate!
      end
    end
  end

  test "validation error includes parameter name and value" do
    SolidQueue.adaptive_polling_min_interval = "invalid"

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval/, error.message)
    assert_match(/invalid/, error.message)
  end

  test "validation with boundary values at minimum thresholds" do
    SolidQueue.adaptive_polling_min_interval = 0.001
    SolidQueue.adaptive_polling_max_interval = 0.002
    SolidQueue.adaptive_polling_backoff_factor = 1.000001
    SolidQueue.adaptive_polling_speedup_factor = 0.999999
    SolidQueue.adaptive_polling_window_size = 3

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation with boundary values at maximum thresholds" do
    SolidQueue.adaptive_polling_min_interval = 0.3
    SolidQueue.adaptive_polling_max_interval = 300.0
    SolidQueue.adaptive_polling_backoff_factor = 5.0
    SolidQueue.adaptive_polling_speedup_factor = 0.1
    SolidQueue.adaptive_polling_window_size = 1000

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation with very large interval ratio at threshold" do
    SolidQueue.adaptive_polling_min_interval = 0.001
    SolidQueue.adaptive_polling_max_interval = 1.0

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation with perfect ratio at minimum threshold" do
    SolidQueue.adaptive_polling_min_interval = 1.0
    SolidQueue.adaptive_polling_max_interval = 2.0

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation with NaN values raises appropriate errors" do
    SolidQueue.adaptive_polling_min_interval = Float::NAN

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "validation with infinity values raises appropriate errors" do
    SolidQueue.adaptive_polling_max_interval = Float::INFINITY

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_max_interval.*is too large/, error.message)
  end

  test "validation with extremely small positive numbers" do
    SolidQueue.adaptive_polling_min_interval = 1e-10
    SolidQueue.adaptive_polling_max_interval = 1e-9

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval.*is too small/, error.message)
  end

  test "validation handles precision edge cases" do
    SolidQueue.adaptive_polling_min_interval = 0.01000001
    SolidQueue.adaptive_polling_max_interval = 5.0000001
    SolidQueue.adaptive_polling_backoff_factor = 1.0000001
    SolidQueue.adaptive_polling_speedup_factor = 0.9999999

    assert_nothing_raised do
      SolidQueue::AdaptivePoller::Config.validate!
    end
  end

  test "validation with null and undefined values" do
    SolidQueue.adaptive_polling_window_size = nil

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidWindowSizeError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_window_size must be a positive integer/, error.message)
  end

  test "validation with boolean values raises type errors" do
    SolidQueue.adaptive_polling_min_interval = true

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval must be a positive number/, error.message)
  end

  test "validation with array values raises type errors" do
    SolidQueue.adaptive_polling_backoff_factor = [ 1.5 ]

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_backoff_factor must be a positive number/, error.message)
  end

  test "validation with hash values raises type errors" do
    SolidQueue.adaptive_polling_speedup_factor = { value: 0.7 }

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidFactorError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_speedup_factor must be a positive number/, error.message)
  end

  test "multiple validation errors are caught individually" do
    SolidQueue.adaptive_polling_min_interval = -1
    SolidQueue.adaptive_polling_backoff_factor = 0.5

    error = assert_raises SolidQueue::AdaptivePoller::Config::InvalidIntervalError do
      SolidQueue::AdaptivePoller::Config.validate!
    end

    assert_match(/adaptive_polling_min_interval/, error.message)
  end

  test "configuration summary handles edge case values correctly" do
    SolidQueue.adaptive_polling_min_interval = 0.001
    SolidQueue.adaptive_polling_max_interval = 1000.0
    SolidQueue.adaptive_polling_backoff_factor = 4.999
    SolidQueue.adaptive_polling_speedup_factor = 0.101

    summary = SolidQueue::AdaptivePoller::Config.configuration_summary

    assert_equal "0.001s", summary[:min_interval]
    assert_equal "1000.0s", summary[:max_interval]
    assert_equal 4.999, summary[:backoff_factor]
    assert_equal 0.101, summary[:speedup_factor]
    assert_equal 1000000.0, summary[:interval_ratio]
  end
end
