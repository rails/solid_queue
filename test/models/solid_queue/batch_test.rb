require "test_helper"

class SolidQueue::BatchTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.destroy_all
    SolidQueue::Batch.destroy_all
  end

  class BatchWithArgumentsJob < ApplicationJob
    def perform(batch, arg1, arg2)
      Rails.logger.info "Hi #{batch.batch_id}, #{arg1}, #{arg2}!"
    end
  end

  class NiceJob < ApplicationJob
    retry_on Exception, wait: 1.second

    def perform(arg)
      Rails.logger.info "Hi #{arg}!"
    end
  end

  test "batch will be completed on success" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { }
    job_batch = SolidQueue::Batch.find_by(id: batch.id)
    assert_not_nil job_batch.on_finish
    assert_equal BatchCompletionJob.name, job_batch.on_finish["job_class"]
  end

  test "batch will be completed on finish" do
    batch = SolidQueue::Batch.enqueue(on_success: BatchCompletionJob) { }
    job_batch = SolidQueue::Batch.find_by(id: batch.id)
    assert_not_nil job_batch.on_success
    assert_equal BatchCompletionJob.name, job_batch.on_success["job_class"]
  end

  test "sets the batch_id on jobs created inside of the enqueue block" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
      NiceJob.perform_later("people")
    end

    assert_equal 2, SolidQueue::Job.count
    assert_equal [ batch.id ] * 2, SolidQueue::Job.last(2).map(&:batch_id)
  end

  test "batch id is present inside the block" do
    assert_nil SolidQueue::Batch.current_batch_id
    SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      assert_not_nil SolidQueue::Batch.current_batch_id
    end
    assert_nil SolidQueue::Batch.current_batch_id
  end

  test "allow arguments and options for callbacks" do
    SolidQueue::Batch.enqueue(
      on_finish: BatchWithArgumentsJob.new(1, 2).set(queue: :batch),
    ) do
      NiceJob.perform_later("world")
    end

    assert_not_nil SolidQueue::Batch.last.on_finish["arguments"]
    assert_equal SolidQueue::Batch.last.on_finish["arguments"], [ 1, 2 ]
    assert_equal SolidQueue::Batch.last.on_finish["queue_name"], "batch"
  end

  test "creates batch with metadata" do
    SolidQueue::Batch.enqueue(
      source: "test", priority: "high", user_id: 123
    ) do
      NiceJob.perform_later("world")
    end

    assert_not_nil SolidQueue::Batch.last.metadata
    assert_equal SolidQueue::Batch.last.metadata["source"], "test"
    assert_equal SolidQueue::Batch.last.metadata["priority"], "high"
    assert_equal SolidQueue::Batch.last.metadata["user_id"], 123
  end

  test "creates batch with description" do
    SolidQueue::Batch.enqueue(
      description: "Process user imports for account 123",
      on_finish: BatchCompletionJob
    ) do
      NiceJob.perform_later("world")
    end

    assert_equal "Process user imports for account 123", SolidQueue::Batch.last.description
  end

  test "instance enqueue with preset attributes" do
    batch = SolidQueue::Batch.new
    batch.description = "My batch"
    batch.on_finish = BatchCompletionJob
    batch.enqueue do
      NiceJob.perform_later("world")
    end

    assert_equal "My batch", batch.description
    assert_equal BatchCompletionJob.name, batch.on_finish["job_class"]
    assert_equal 1, batch.jobs.count
    assert batch.enqueued?
  end

  test "cannot enqueue finished batch" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
    end

    batch.update_columns(finished_at: Time.current)

    assert_raises(SolidQueue::Batch::AlreadyFinished) do
      batch.enqueue { NiceJob.perform_later("another") }
    end
  end
end
