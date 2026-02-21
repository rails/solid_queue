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
      assert_raises RuntimeError do
        claimed_execution.perform
      end
    end

    assert_not job.reload.finished?
    assert job.failed?
    assert_equal "RuntimeError", job.failed_execution.exception_class
    assert_equal "This is a RuntimeError exception", job.failed_execution.message
    assert_match /\/app\/jobs\/raising_job\.rb:\d+:in [`'](RaisingJob#)?perform'/, job.failed_execution.backtrace.first

    assert_equal @process, claimed_execution.process
  end

  test "job failures are reported via Rails error subscriber" do
    subscriber = ErrorBuffer.new

    assert_raises RuntimeError do
      with_error_subscriber(subscriber) do
        claimed_execution = prepare_and_claim_job RaisingJob.perform_later(RuntimeError, "B")

        claimed_execution.perform
      end
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

  test "release bypasses concurrency limits when no other job with same key is executing" do
    job_result = JobResult.create!(queue_name: "default", status: "")

    # Create Job A with concurrency limit and claim it
    job_a = DiscardableUpdateResultJob.perform_later(job_result, name: "A")
    solid_queue_job_a = SolidQueue::Job.find_by(active_job_id: job_a.job_id)
    SolidQueue::ReadyExecution.claim(solid_queue_job_a.queue_name, 1, @process.id)
    claimed_execution_a = SolidQueue::ClaimedExecution.find_by(job_id: solid_queue_job_a.id)
    assert claimed_execution_a

    # Release job A - no other job with same key is running, so it should go to ready
    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::ReadyExecution.count } => 1 do
      claimed_execution_a.release
    end

    assert solid_queue_job_a.reload.ready?
  end

  test "fail with error" do
    claimed_execution = prepare_and_claim_job AddToBufferJob.perform_later(42)
    job = claimed_execution.job

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::FailedExecution.count } => 1 do
      claimed_execution.failed_with(RuntimeError.new)
    end

    assert job.reload.failed?
  end

  test "fail with error when a failed execution already exists updates the existing one" do
    claimed_execution = prepare_and_claim_job AddToBufferJob.perform_later(42)
    job = claimed_execution.job

    # Simulate corrupted state: a failed execution already exists for this job
    SolidQueue::FailedExecution.create!(job_id: job.id, exception: RuntimeError.new("old error"))

    assert_no_difference -> { SolidQueue::FailedExecution.count } do
      assert_difference -> { SolidQueue::ClaimedExecution.count }, -1 do
        claimed_execution.failed_with(RuntimeError.new("new error"))
      end
    end

    assert_equal "new error", job.failed_execution.message
  end

  test "perform job with missing class fails gracefully" do
    job = create_job_with_missing_class
    claimed_execution = claim_job(job)

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::FailedExecution.count } => 1 do
      assert_raises NameError do
        claimed_execution.perform
      end
    end

    assert job.reload.failed?
  end

  test "perform concurrency-controlled job with missing class fails gracefully" do
    job = create_job_with_missing_class(concurrency_key: "test_key")
    claimed_execution = claim_job(job)

    assert_difference -> { SolidQueue::ClaimedExecution.count } => -1, -> { SolidQueue::FailedExecution.count } => 1 do
      assert_raises NameError do
        claimed_execution.perform
      end
    end

    assert job.reload.failed?
  end

  test "dispatch job with missing class and concurrency key skips concurrency controls" do
    job = create_job_with_missing_class(concurrency_key: "test_key")

    assert_not job.concurrency_limited?

    job.prepare_for_execution

    assert job.reload.ready?
    assert_equal 0, SolidQueue::BlockedExecution.where(job_id: job.id).count
    assert_equal 0, SolidQueue::Semaphore.where(key: "test_key").count
  end

  test "provider_job_id is available within job execution" do
    job = ProviderJobIdJob.perform_later
    claimed_execution = prepare_and_claim_job job
    claimed_execution.perform

    assert_equal "provider_job_id: #{job.provider_job_id}", JobBuffer.last_value
  end

  private
    def prepare_and_claim_job(active_job, process: @process)
      job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)
      job.prepare_for_execution
      claim_job(job, process: process)
    end

    def create_job_with_missing_class(concurrency_key: nil)
      SolidQueue::Job.create!(
        queue_name: "background",
        class_name: "RemovedJobClass",
        active_job_id: SecureRandom.uuid,
        arguments: { "job_class" => "RemovedJobClass", "arguments" => [] },
        concurrency_key: concurrency_key,
        scheduled_at: Time.current
      )
    end

    def claim_job(job, process: @process)
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
