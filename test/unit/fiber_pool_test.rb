require "test_helper"

class FiberPoolTest < ActiveSupport::TestCase
  setup do
    @original_on_thread_error = SolidQueue.on_thread_error
  end

  teardown do
    SolidQueue.on_thread_error = @original_on_thread_error
  end

  test "tracks available capacity across fibers" do
    started = Queue.new
    release = Queue.new

    execution = Struct.new(:started, :release) do
      def perform
        started << true
        release.pop
      end
    end

    pool = SolidQueue::FiberPool.new(1, 2)

    2.times { pool.post(execution.new(started, release)) }
    2.times { started.pop }

    wait_for(timeout: 1.second) { pool.available_capacity.zero? }

    assert_equal 2, pool.capacity
    assert_equal 0, pool.available_capacity
    assert_not pool.available?

    2.times { release << true }

    wait_for(timeout: 1.second) { pool.available_capacity == 2 }

    assert_equal 2, pool.available_capacity
    assert pool.available?
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  test "runs sleeping work concurrently within a single thread" do
    finished = Queue.new

    execution = Struct.new(:finished) do
      def perform
        sleep 0.2
        finished << true
      end
    end

    pool = SolidQueue::FiberPool.new(1, 2)
    started_at = Concurrent.monotonic_time

    2.times { pool.post(execution.new(finished)) }

    2.times { Timeout.timeout(1.second) { finished.pop } }
    elapsed = Concurrent.monotonic_time - started_at

    assert_operator elapsed, :<, 0.35
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  test "calls on_available when fiber capacity is restored" do
    started = Queue.new
    release = Queue.new
    available = Queue.new

    execution = Struct.new(:started, :release) do
      def perform
        started << true
        release.pop
      end
    end

    pool = SolidQueue::FiberPool.new(1, 1, on_available: -> { available << true })

    pool.post(execution.new(started, release))
    started.pop
    wait_for(timeout: 1.second) { pool.available_capacity.zero? }

    release << true

    Timeout.timeout(1.second) { available.pop }
    wait_for(timeout: 1.second) { pool.available_capacity == 1 }
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  test "returns false when in-flight work exceeds the shutdown timeout" do
    started = Queue.new
    release = Queue.new
    finished = Queue.new
    errors = Queue.new

    SolidQueue.on_thread_error = ->(error) { errors << error }

    execution = Struct.new(:started, :release, :finished) do
      def perform
        started << true
        release.pop
        finished << true
      end
    end

    pool = SolidQueue::FiberPool.new(1, 1)

    pool.post(execution.new(started, release, finished))
    started.pop

    pool.shutdown

    assert_not pool.wait_for_termination(0.05)
    assert_nil finished.pop(true) rescue ThreadError
    assert_equal 0, pool.available_capacity

    release << true

    Timeout.timeout(1.second) { finished.pop }
    assert pool.wait_for_termination(1.second)
    assert_equal 1, pool.available_capacity
    assert_nil errors.pop(true) rescue ThreadError
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end
end
