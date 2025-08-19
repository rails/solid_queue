require "test_helper"

class FailureScenariosTest < ActiveSupport::TestCase
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

    @worker&.stop
    JobBuffer.clear
  end

  test "worker handles database disconnection gracefully during polling" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    SolidQueue::ReadyExecution.stubs(:claim).raises(ActiveRecord::ConnectionNotEstablished.new("Database connection lost"))

    assert_raises ActiveRecord::ConnectionNotEstablished do
      @worker.send(:poll)
    end
  end

  test "worker continues functioning after temporary database errors" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    @worker.stubs(:claim_executions).raises(ActiveRecord::ConnectionNotEstablished.new("Temporary connection issue")).then.returns([])

    assert_raises ActiveRecord::ConnectionNotEstablished do
      @worker.send(:poll)
    end

    assert_nothing_raised do
      @worker.send(:poll)
    end
  end

  test "adaptive poller handles clock skew and time inconsistencies" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    Time.stubs(:current).returns(
      Time.parse("2024-01-01 12:00:00"),
      Time.parse("2024-01-01 11:59:00"),
      Time.parse("2024-01-01 12:00:01")
    )

    poll_result = { job_count: 1, execution_time: 0.05 }

    interval = nil
    assert_nothing_raised do
      interval = poller.next_interval(poll_result)
    end

    assert interval.is_a?(Numeric)
    assert interval > 0
  end

  test "worker handles corrupted polling stats gracefully" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    @worker.instance_variable_set(:@polling_stats, { corrupted: "data" })

    assert_nothing_raised do
      @worker.send(:update_polling_stats, 5)
    end
  end

  test "adaptive poller handles extremely large job counts" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    poll_result = { job_count: 2**31 - 1, execution_time: 10.0 }

    interval = nil
    assert_nothing_raised do
      interval = poller.next_interval(poll_result)
    end

    assert interval.is_a?(Numeric)
    assert interval > 0
  end

  test "worker handles thread pool exhaustion" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    @worker.pool.stubs(:post).raises(Concurrent::RejectedExecutionError.new("Thread pool full"))

    executions = [ mock("execution") ]
    @worker.stubs(:claim_executions).returns(executions)

    begin
      @worker.send(:poll)
    rescue Concurrent::RejectedExecutionError => e
      assert_match(/Thread pool full/, e.message)
    end
  end

  test "adaptive poller handles negative execution times" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    poll_result = { job_count: 1, execution_time: -0.1 }

    interval = nil
    assert_nothing_raised do
      interval = poller.next_interval(poll_result)
    end

    assert interval.is_a?(Numeric)
    assert interval > 0
  end

  test "worker handles logger being nil during error conditions" do
    original_logger = SolidQueue.logger
    SolidQueue.logger = nil

    assert_nothing_raised do
      @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    end

  ensure
    SolidQueue.logger = original_logger
  end

  test "adaptive poller handles circular buffer overflow" do
    SolidQueue.adaptive_polling_window_size = 2
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    poll_result = { job_count: 1, execution_time: 0.05 }

    assert_nothing_raised do
      100.times do
        poller.next_interval(poll_result)
      end
    end
  end

  test "worker handles invalid process_id during initialization" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    @worker.stubs(:process_id).raises(StandardError.new("Process ID unavailable"))

    assert_nothing_raised do
      @worker.send(:initialize, queues: "background", threads: 1, polling_interval: 0.1)
    end
  end

  test "adaptive poller handles stats window corruption" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    corrupted_window = mock("corrupted_window")
    corrupted_window.stubs(:push).raises(NoMethodError.new("Buffer corrupted"))
    corrupted_window.stubs(:size).returns(0)

    poller.instance_variable_set(:@stats_window, corrupted_window)

    poll_result = { job_count: 1, execution_time: 0.05 }

    interval = nil
    assert_nothing_raised do
      interval = poller.next_interval(poll_result)
    end

    assert interval.is_a?(Numeric)
    assert interval > 0
  end

  test "worker handles ActiveRecord readonly database" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    SolidQueue::ReadyExecution.stubs(:claim).raises(ActiveRecord::ReadOnlyError.new("Database is readonly"))

    assert_raises ActiveRecord::ReadOnlyError do
      @worker.send(:poll)
    end
  end

  test "adaptive poller maintains consistency under memory pressure" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    GC.stubs(:start).raises(NoMemoryError.new("GC failed"))

    poll_result = { job_count: 1, execution_time: 0.05 }

    intervals = []
    assert_nothing_raised do
      10.times do
        intervals << poller.next_interval(poll_result)
      end
    end

    intervals.each do |interval|
      assert interval.is_a?(Numeric)
      assert interval > 0
    end
  end

  test "worker handles signal interruption during polling" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    @worker.stubs(:claim_executions).raises(Interrupt.new("SIGINT received"))

    assert_raises Interrupt do
      @worker.send(:poll)
    end
  end

  test "adaptive poller handles extremely long execution times" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)

    poll_result = { job_count: 1, execution_time: 86400.0 }

    interval = nil
    assert_nothing_raised do
      interval = poller.next_interval(poll_result)
    end

    assert interval.is_a?(Numeric)
    assert interval > 0
    assert interval <= SolidQueue.adaptive_polling_max_interval
  end

  test "worker handles configuration changes during runtime" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)

    original_max = SolidQueue.adaptive_polling_max_interval
    SolidQueue.adaptive_polling_max_interval = 1.0

    assert_nothing_raised do
      @worker.send(:poll)
    end

  ensure
    SolidQueue.adaptive_polling_max_interval = original_max
  end
end
