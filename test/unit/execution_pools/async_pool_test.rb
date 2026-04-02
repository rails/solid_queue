require "test_helper"

class AsyncPoolTest < Minitest::Test
  Execution = Struct.new(:started, :results, :pause) do
    def perform
      started << true if started
      sleep(pause) if pause
      results << [ Thread.current.object_id, Fiber.current.object_id ] if results
    end
  end

  def test_raises_a_clear_error_when_the_async_gem_is_unavailable
    load_error = LoadError.new("cannot load such file -- async")

    SolidQueue::ExecutionPools::AsyncPool.any_instance.expects(:require).with("async").raises(load_error)

    error = assert_raises SolidQueue::ExecutionPools::AsyncPool::MissingDependencyError do
      SolidQueue::ExecutionPools::AsyncPool.new(3)
    end

    assert_match /gem "async"/, error.message
  end

  def test_build_treats_fiber_as_an_alias_for_async
    pool = mock

    SolidQueue::ExecutionPools::AsyncPool.expects(:new).with(5, on_state_change: nil).returns(pool)

    assert_equal pool, SolidQueue::ExecutionPools.build(mode: :fiber, size: 5)
  end

  def test_executes_jobs_as_fibers_on_a_single_reactor_thread
    pool = SolidQueue::ExecutionPools::AsyncPool.new(2)
    results = Thread::Queue.new

    pool.post Execution.new(nil, results, 0.05)
    pool.post Execution.new(nil, results, 0.05)

    entries = 2.times.map { Timeout.timeout(1.second) { results.pop } }

    assert_equal 1, entries.map(&:first).uniq.count
    assert_equal 2, entries.map(&:last).uniq.count
    assert_equal 2, pool.available_capacity
    assert_equal 0, pool.metadata[:inflight]
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  def test_waits_for_in_flight_executions_during_shutdown
    pool = SolidQueue::ExecutionPools::AsyncPool.new(1)
    started = Thread::Queue.new

    pool.post Execution.new(started, nil, 0.1)
    Timeout.timeout(1.second) { started.pop }

    pool.shutdown

    assert_nil pool.wait_for_termination(0.01)
    assert pool.wait_for_termination(1.second)
  end
end
