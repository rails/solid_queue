require "test_helper"

class SolidQueue::ClaimedExecutionTest < ActiveSupport::TestCase
  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123", metadata: { queue: "background" })
  end

  test "perform job successfully" do
    claimed_execution = prepare_and_claim_job AddToBufferJob.perform_later(42)
    job = claimed_execution.job
    assert_not job.finished?

    assert_difference -> { SolidQueue::ClaimedExecution.count }, -1 do
      claimed_execution.perform
    end

    assert job.reload.finished?
  end

  test "perform job that fails" do
    claimed_execution = prepare_and_claim_job RaisingJob.perform_later(RuntimeError, "A")
    job = claimed_execution.job

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::FailedExecution.count } => 1 do
      claimed_execution.perform
    end

    assert_not job.reload.finished?
    assert job.failed?
    assert_equal "RuntimeError", job.failed_execution.exception_class
    assert_equal "This is a RuntimeError exception", job.failed_execution.message
    assert_match /app\/jobs\/raising_job\.rb:\d+:in `perform'/, job.failed_execution.backtrace.first

    assert_equal @process, claimed_execution.process
  end

  test "job failures are reported via Rails error subscriber" do
    subscriber = ErrorBuffer.new

    with_error_subscriber(subscriber) do
      claimed_execution = prepare_and_claim_job RaisingJob.perform_later(RuntimeError, "B")

      claimed_execution.perform
    end

    assert_equal 1, subscriber.errors.count
    assert_equal "This is a RuntimeError exception", subscriber.messages.first
  end

  test "release" do
    claimed_execution = prepare_and_claim_job AddToBufferJob.perform_later(42)
    job = claimed_execution.job

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::ReadyExecution.count } => 1 do
      claimed_execution.release
    end

    assert job.reload.ready?
  end

  private
    def prepare_and_claim_job(active_job, process: @process)
      job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)

      job.prepare_for_execution
      assert_difference -> { SolidQueue::ClaimedExecution.count } => +1 do
        SolidQueue::ReadyExecution.claim(job.queue_name, 1, process.id)
      end

      SolidQueue::ClaimedExecution.last
    end

    def with_error_subscriber(subscriber)
      Rails.error.subscribe(subscriber)
      yield
    ensure
      Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
    end
end
