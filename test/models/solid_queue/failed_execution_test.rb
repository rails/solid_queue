require "test_helper"

class SolidQueue::FailedExecutionTest < ActiveSupport::TestCase
  setup do
    @worker = SolidQueue::Worker.new(queues: "background")
    @worker.mode = :inline
  end

  test "run job that fails" do
    RaisingJob.perform_later(RuntimeError, "A")
    @worker.start

    assert_equal 1, SolidQueue::FailedExecution.count
    assert SolidQueue::Job.last.failed?
  end

  test "retry failed job" do
    RaisingJob.perform_later(RuntimeError, "A")
    @worker.start

    assert_difference -> { SolidQueue::FailedExecution.count }, -1 do
      assert_difference -> { SolidQueue::ReadyExecution.count }, +1 do
        SolidQueue::FailedExecution.last.retry
      end
    end
  end

  test "retry failed jobs in bulk" do
    1.upto(5) { |i| RaisingJob.perform_later(RuntimeError, i) }
    1.upto(3) { |i| AddToBufferJob.perform_later(i) }

    @worker.start

    assert_difference -> { SolidQueue::FailedExecution.count }, -5 do
      assert_difference -> { SolidQueue::ReadyExecution.count }, +5 do
        SolidQueue::FailedExecution.retry_all(SolidQueue::Job.all)
      end
    end
  end
end
