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
    job_batch = SolidQueue::Batch.find_by(batch_id: batch.batch_id)
    assert_not_nil job_batch.on_finish
    assert_equal BatchCompletionJob.name, job_batch.on_finish["job_class"]
  end

  test "batch will be completed on finish" do
    batch = SolidQueue::Batch.enqueue(on_success: BatchCompletionJob) { }
    job_batch = SolidQueue::Batch.find_by(batch_id: batch.batch_id)
    assert_not_nil job_batch.on_success
    assert_equal BatchCompletionJob.name, job_batch.on_success["job_class"]
  end

  test "sets the batch_id on jobs created inside of the enqueue block" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
      NiceJob.perform_later("people")
    end

    assert_equal 2, SolidQueue::Job.count
    assert_equal [ batch.batch_id ] * 2, SolidQueue::Job.last(2).map(&:batch_id)
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
      metadata: { source: "test", priority: "high", user_id: 123 }
    ) do
      NiceJob.perform_later("world")
    end

    assert_not_nil SolidQueue::Batch.last.metadata
    assert_equal SolidQueue::Batch.last.metadata["source"], "test"
    assert_equal SolidQueue::Batch.last.metadata["priority"], "high"
    assert_equal SolidQueue::Batch.last.metadata["user_id"], 123
  end
end
