# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TimerTaskTest < ActiveSupport::TestCase
  test "initialization requires a block" do
    assert_raises(ArgumentError) do
      SolidQueue::TimerTask.new(execution_interval: 1)
    end
  end

  test "task runs immediate when run now true" do
    executed = false

    task = SolidQueue::TimerTask.new(run_now: true, execution_interval: 1) do
      executed = true
    end

    sleep 0.1

    assert executed, "Task should have executed immediately"
    task.shutdown
  end

  test "task does not run immediately when run with run_now false" do
    executed = false

    task = SolidQueue::TimerTask.new(run_now: false, execution_interval: 1) do
      executed = true
    end

    sleep 0.1

    assert_not executed, "Task should have executed immediately"
    task.shutdown
  end

  test "task repeats" do
    executions = 0

    task = SolidQueue::TimerTask.new(execution_interval: 0.1, run_now: false) do
      executions += 1
    end

    sleep(0.5) # Wait to accumulate some executions

    assert executions > 3, "The block should be executed repeatedly"

    task.shutdown
  end

  test "task stops on shutdown" do
    executions = 0

    task = SolidQueue::TimerTask.new(execution_interval: 0.1, run_now: false) { executions += 1 }

    sleep(0.3) # Let the task run a few times

    task.shutdown

    current_executions = executions

    sleep(0.5) # Ensure no more executions after shutdown

    assert_equal current_executions, executions, "The task should stop executing after shutdown"
  end

  test "calls handle_thread_error if task raises" do
    task = SolidQueue::TimerTask.new(execution_interval: 0.1) do
      raise ExpectedTestError.new
    end
    task.expects(:handle_thread_error).with(instance_of(ExpectedTestError))

    sleep(0.2) # Give some time for the task to run and handle the error

    task.shutdown
  end
end
