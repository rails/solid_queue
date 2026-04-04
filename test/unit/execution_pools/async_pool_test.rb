require "test_helper"

class AsyncPoolTest < Minitest::Test
  Execution = Struct.new(:started, :results, :pause) do
    def perform
      started << true if started
      sleep(pause) if pause
      results << [ Thread.current.object_id, Fiber.current.object_id ] if results
    end
  end

  CancelledExecution = Struct.new(:started) do
    def perform
      started << true if started
      raise Async::Stop.new
    end
  end

  def test_raises_a_clear_error_when_the_async_gem_is_unavailable
    load_error = LoadError.new("cannot load such file -- async")

    SolidQueue::ExecutionPools::AsyncPool.expects(:require).with("async").raises(load_error)

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

  def test_raises_a_clear_error_when_isolation_level_is_not_fiber
    error = assert_raises SolidQueue::ExecutionPools::AsyncPool::UnsupportedIsolationLevelError do
      SolidQueue::ExecutionPools::AsyncPool.new(3)
    end

    assert_match /isolation_level = :fiber/, error.message
  end

  def test_adds_io_timeout_compatibility_for_older_rubies
    io_class = Class.new

    SolidQueue::ExecutionPools::AsyncPool.ensure_io_timeout_compatibility!(io_class)

    io = io_class.new
    assert_nil io.timeout

    io.timeout = 1.second

    assert_equal 1.second, io.timeout
    assert io_class.const_defined?(:TimeoutError, false)
  end

  def test_executes_jobs_as_fibers_on_a_single_reactor_thread
    with_execution_isolation(:fiber) do
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
  end

  def test_waits_for_in_flight_executions_during_shutdown
    with_execution_isolation(:fiber) do
      pool = SolidQueue::ExecutionPools::AsyncPool.new(1)
      started = Thread::Queue.new

      pool.post Execution.new(started, nil, 0.1)
      Timeout.timeout(1.second) { started.pop }

      pool.shutdown

      assert_nil pool.wait_for_termination(0.01)
      assert pool.wait_for_termination(1.second)
    ensure
      pool&.shutdown
      pool&.wait_for_termination(1.second)
    end
  end

  def test_shutdown_wakes_the_reactor_when_idle
    with_execution_isolation(:fiber) do
      pool = SolidQueue::ExecutionPools::AsyncPool.new(1)

      pool.shutdown

      assert pool.wait_for_termination(1.second)
    ensure
      pool&.shutdown
      pool&.wait_for_termination(1.second)
    end
  end

  def test_marks_the_pool_as_fatal_when_an_execution_is_cancelled
    with_execution_isolation(:fiber) do
      notifications = Thread::Queue.new
      started = Thread::Queue.new
      reported_errors = []
      original_on_thread_error = SolidQueue.on_thread_error
      SolidQueue.on_thread_error = ->(error) { reported_errors << error.class.name }

      pool = SolidQueue::ExecutionPools::AsyncPool.new(1, on_state_change: -> { notifications << :changed })

      pool.post CancelledExecution.new(started)
      Timeout.timeout(1.second) { started.pop }
      Timeout.timeout(1.second) { notifications.pop }

      error = assert_raises(Async::Stop) { pool.available_capacity }
      assert_equal [ error.class.name ], reported_errors
      assert_raises(Async::Stop) { pool.metadata }
    ensure
      SolidQueue.on_thread_error = original_on_thread_error
      pool&.shutdown
      pool&.wait_for_termination(1.second)
    end
  end
end
