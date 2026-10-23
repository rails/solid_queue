require "test_helper"

class ReactorThreadPoolTest < Minitest::Test
  Execution = Struct.new(:started, :results, :pause) do
    def perform
      started << true if started
      sleep(pause) if pause
      results << [ Thread.current.object_id, Async::Task.current.reactor.object_id ] if results
    end
  end

  CancelledExecution = Struct.new(:started) do
    def perform
      started << true if started
      raise Async::Stop.new
    end
  end

  def test_builds_a_reactor_thread_pool
    pool = mock

    SolidQueue::ReactorThreadPool.expects(:new).with(5, on_idle: nil, on_unrecoverable_error: nil).returns(pool)

    assert_equal pool, SolidQueue::Pool.build(type: :reactor_thread, size: 5)
  end

  def test_executes_jobs_concurrently_on_separate_threads_each_inside_a_reactor
    pool = SolidQueue::ReactorThreadPool.new(2)
    started = Thread::Queue.new
    results = Thread::Queue.new

    pool.post Execution.new(started, results, 0.1)
    pool.post Execution.new(started, results, 0.1)

    2.times { Timeout.timeout(1.second) { started.pop } }
    entries = 2.times.map { Timeout.timeout(1.second) { results.pop } }

    assert_equal 2, entries.map(&:first).uniq.count
    assert_equal 2, entries.map(&:last).uniq.count
    assert_equal 2, pool.available_capacity
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  def test_keeps_the_same_reactor_across_jobs_on_a_thread
    pool = SolidQueue::ReactorThreadPool.new(1)
    results = Thread::Queue.new

    pool.post Execution.new(nil, results, nil)
    first = Timeout.timeout(1.second) { results.pop }
    pool.post Execution.new(nil, results, nil)
    second = Timeout.timeout(1.second) { results.pop }

    assert_equal first, second
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  def test_waits_for_in_flight_executions_during_shutdown
    pool = SolidQueue::ReactorThreadPool.new(1)
    started = Thread::Queue.new

    pool.post Execution.new(started, nil, 0.1)
    Timeout.timeout(1.second) { started.pop }

    pool.shutdown

    assert_equal false, pool.wait_for_termination(0.01)
    assert pool.wait_for_termination(1.second)
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  def test_starts_threads_lazily_so_the_pool_can_be_built_before_forking
    pool = SolidQueue::ReactorThreadPool.new(1)

    pid = fork do
      results = Thread::Queue.new
      pool.post Execution.new(nil, results, nil)
      Timeout.timeout(1.second) { results.pop }
      pool.shutdown
      pool.wait_for_termination(1.second)
      exit!(0)
    end

    _, status = Process.waitpid2(pid)
    assert_equal 0, status.exitstatus
  ensure
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end

  def test_marks_the_pool_as_fatal_when_an_execution_is_cancelled
    notifications = Thread::Queue.new
    started = Thread::Queue.new
    reported_errors = []
    original_on_thread_error = SolidQueue.on_thread_error
    SolidQueue.on_thread_error = ->(error) { reported_errors << error.class.name }

    pool = SolidQueue::ReactorThreadPool.new(1, on_idle: -> { notifications << :changed })

    pool.post CancelledExecution.new(started)
    Timeout.timeout(1.second) { started.pop }
    Timeout.timeout(1.second) { notifications.pop }

    error = assert_raises(Async::Stop) { pool.available_capacity }
    assert_equal [ error.class.name ], reported_errors
  ensure
    SolidQueue.on_thread_error = original_on_thread_error
    pool&.shutdown
    pool&.wait_for_termination(1.second)
  end
end
