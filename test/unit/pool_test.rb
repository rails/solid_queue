require "test_helper"

class PoolTest < ActiveSupport::TestCase
  test "tracks available capacity while work is in flight" do
    started = Queue.new
    release = Queue.new

    execution = Struct.new(:started, :release) do
      def perform
        started << true
        release.pop
      end
    end.new(started, release)

    pool = SolidQueue::Pool.new(1)

    assert_equal 1, pool.capacity
    assert_equal 1, pool.available_capacity
    assert_equal 1, pool.idle_threads
    assert pool.available?
    assert pool.idle?

    pool.post(execution)
    started.pop

    wait_for(timeout: 1.second) { pool.available_capacity.zero? }

    assert_equal 0, pool.available_capacity
    assert_equal 0, pool.idle_threads
    assert_not pool.available?
    assert_not pool.idle?

    release << true

    wait_for(timeout: 1.second) { pool.available_capacity == 1 }

    assert_equal 1, pool.available_capacity
    assert_equal 1, pool.idle_threads
    assert pool.available?
    assert pool.idle?
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  test "calls on_available when capacity is restored" do
    started = Queue.new
    release = Queue.new
    available = Queue.new

    execution = Struct.new(:started, :release) do
      def perform
        started << true
        release.pop
      end
    end.new(started, release)

    pool = SolidQueue::Pool.new(1, on_available: -> { available << true })

    pool.post(execution)
    started.pop
    wait_for(timeout: 1.second) { pool.available_capacity.zero? }

    release << true

    Timeout.timeout(1.second) { available.pop }
    wait_for(timeout: 1.second) { pool.available_capacity == 1 }
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end
end
