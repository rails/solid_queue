require "test_helper"
require "concurrent"

class ThreadSafetyTest < ActiveSupport::TestCase
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

    @workers&.each(&:stop)
    JobBuffer.clear
  end

  test "multiple workers with adaptive polling operate independently" do
    @workers = []

    3.times do |i|
      worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1 + (i * 0.05))
      @workers << worker
      assert_not_nil worker.adaptive_poller
    end

    pollers = @workers.map(&:adaptive_poller)
    pollers.combination(2).each do |poller1, poller2|
      assert_not_same poller1, poller2
    end

    @workers.each_with_index do |worker, i|
      base_interval = worker.adaptive_poller.base_interval
      assert_in_delta 0.1 + (i * 0.05), base_interval, 0.01
    end
  end

  test "concurrent access to polling stats is thread-safe" do
    worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    @workers = [ worker ]

    threads = []
    total_updates = 100
    updates_per_thread = 10

    (total_updates / updates_per_thread).times do
      threads << Thread.new do
        updates_per_thread.times do
          worker.send(:update_polling_stats, rand(5))
          sleep(0.001)
        end
      end
    end

    threads.each(&:join)

    stats = worker.instance_variable_get(:@polling_stats)
    assert stats[:total_polls] <= total_updates
    assert stats[:total_jobs_claimed] >= 0
    assert stats[:empty_polls] >= 0
    assert stats[:total_polls] >= stats[:empty_polls]
  end

  test "adaptive poller handles concurrent interval calculations" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)
    intervals = Concurrent::Array.new
    errors = Concurrent::Array.new

    threads = []
    20.times do
      threads << Thread.new do
        begin
          10.times do
            poll_result = {
              job_count: rand(5),
              execution_time: rand * 0.1,
              pool_idle: [ true, false ].sample
            }
            interval = poller.next_interval(poll_result)
            intervals << interval
            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors, "Concurrent access caused errors: #{errors.map(&:message).join(', ')}"

    intervals.each do |interval|
      assert interval.is_a?(Numeric)
      assert interval > 0
      assert interval >= SolidQueue.adaptive_polling_min_interval
      assert interval <= SolidQueue.adaptive_polling_max_interval
    end

    assert_equal 200, intervals.size
  end

  test "circular buffer is thread-safe under concurrent access" do
    buffer = SolidQueue::CircularBuffer.new(10)
    stored_items = Concurrent::Array.new
    errors = Concurrent::Array.new

    threads = []
    10.times do |thread_id|
      threads << Thread.new do
        begin
          20.times do |item_id|
            item = { thread: thread_id, item: item_id, timestamp: Time.current }
            buffer.push(item)
            stored_items << item
            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors, "Concurrent access to buffer caused errors: #{errors.map(&:message).join(', ')}"

    assert_operator buffer.size, :<=, 10

    recent_items = buffer.recent(5)
    assert_equal 5, recent_items.size
    recent_items.each do |item|
      assert item.is_a?(Hash)
      assert item.key?(:thread)
      assert item.key?(:item)
      assert item.key?(:timestamp)
    end
  end

  test "worker pool operations are thread-safe with adaptive polling" do
    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.1)
    @workers = [ worker ]

    job_count = 20
    job_count.times do |i|
      AddToBufferJob.perform_later("concurrent_job_#{i}")
    end

    worker.start
    sleep(2)

    worker.stop

    processed_jobs = JobBuffer.values
    assert_operator processed_jobs.size, :>, 0

    assert_equal processed_jobs.size, processed_jobs.uniq.size
  end

  test "adaptive polling configuration validation is thread-safe" do
    errors = Concurrent::Array.new
    successes = Concurrent::AtomicFixnum.new(0)

    threads = []
    10.times do
      threads << Thread.new do
        begin
          50.times do
            SolidQueue::AdaptivePoller::Config.validate!
            successes.increment
            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors
    assert_equal 500, successes.value
  end

  test "worker initialization with adaptive polling is thread-safe" do
    workers = Concurrent::Array.new
    errors = Concurrent::Array.new

    threads = []
    5.times do |i|
      threads << Thread.new do
        begin
          worker = SolidQueue::Worker.new(
            queues: "background_#{i}",
            threads: 1,
            polling_interval: 0.1 + (i * 0.01)
          )
          workers << worker
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    workers.each(&:stop)

    assert_empty errors, "Concurrent worker initialization caused errors: #{errors.map(&:message).join(', ')}"
    assert_equal 5, workers.size

    workers.each do |worker|
      assert_not_nil worker.adaptive_poller
    end

    pollers = workers.map(&:adaptive_poller)
    pollers.combination(2).each do |poller1, poller2|
      assert_not_same poller1, poller2
    end
  end

  test "logging operations are thread-safe during high concurrency" do
    worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    @workers = [ worker ]

    logged_messages = Concurrent::Array.new
    errors = Concurrent::Array.new

    original_logger = SolidQueue.logger
    SolidQueue.logger = Logger.new(StringIO.new).tap do |logger|
      logger.define_singleton_method(:info) do |message|
        logged_messages << message
      end
      logger.define_singleton_method(:error) do |message|
        logged_messages << message
      end
      logger.define_singleton_method(:debug) do |message|
        logged_messages << message
      end
    end

    threads = []
    10.times do
      threads << Thread.new do
        begin
          20.times do
            worker.send(:log_polling_stats) if worker.send(:should_log_stats?)
            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors, "Concurrent logging caused errors: #{errors.map(&:message).join(', ')}"

  ensure
    SolidQueue.logger = original_logger
  end

  test "adaptive poller state transitions are atomic" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)
    state_snapshots = Concurrent::Array.new
    errors = Concurrent::Array.new

    threads = []
    20.times do
      threads << Thread.new do
        begin
          10.times do
            before_interval = poller.current_interval

            poll_result = { job_count: rand(3), execution_time: rand * 0.05 }
            new_interval = poller.next_interval(poll_result)

            after_interval = poller.current_interval

            state_snapshots << {
              before: before_interval,
              calculated: new_interval,
              after: after_interval
            }

            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors, "State transition errors: #{errors.map(&:message).join(', ')}"

    state_snapshots.each do |snapshot|
      assert_equal snapshot[:calculated], snapshot[:after]

      [ snapshot[:before], snapshot[:calculated], snapshot[:after] ].each do |interval|
        assert interval >= SolidQueue.adaptive_polling_min_interval
        assert interval <= SolidQueue.adaptive_polling_max_interval
      end
    end
  end

  test "memory consistency under concurrent access" do
    poller = SolidQueue::AdaptivePoller.new(base_interval: 0.1)
    memory_values = Concurrent::Hash.new
    errors = Concurrent::Array.new

    threads = []

    5.times do |i|
      threads << Thread.new do
        begin
          100.times do
            memory_values["base_interval_#{i}"] ||= []
            memory_values["base_interval_#{i}"] << poller.base_interval

            memory_values["current_interval_#{i}"] ||= []
            memory_values["current_interval_#{i}"] << poller.current_interval

            sleep(0.001)
          end
        rescue => e
          errors << e
        end
      end
    end

    5.times do |i|
      threads << Thread.new do
        begin
          50.times do
            poll_result = { job_count: i % 3, execution_time: (i % 10) * 0.01 }
            poller.next_interval(poll_result)
            sleep(0.002)
          end
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    assert_empty errors, "Memory consistency errors: #{errors.map(&:message).join(', ')}"

    memory_values.each do |key, values|
      values.each do |value|
        assert value.is_a?(Numeric)
        assert value > 0
      end
    end
  end
end
