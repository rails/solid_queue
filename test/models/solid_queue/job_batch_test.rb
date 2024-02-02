require "test_helper"

class SolidQueue::JobBatchTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.destroy_all
    SolidQueue::JobBatch.destroy_all
  end

  class NiceJob < ApplicationJob
    retry_on Exception, wait: 1.second

    def perform(arg)
      Rails.logger.info "Hi #{arg}!"
    end
  end

  test "batch will be completed on success" do
    batch = SolidQueue::JobBatch.enqueue(on_finish: BatchCompletionJob) {}
    assert_equal "success", batch.completion_type
    assert_equal BatchCompletionJob.name, batch.job_class
  end

  test "batch will be completed on finish" do
    batch = SolidQueue::JobBatch.enqueue(on_success: BatchCompletionJob) {}
    assert_equal "success", batch.completion_type
    assert_equal BatchCompletionJob.name, batch.job_class
  end

  test "sets the batch_id on jobs created inside of the enqueue block" do
    batch = SolidQueue::JobBatch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
      NiceJob.perform_later("people")
    end

    assert_equal 2, SolidQueue::Job.count
    assert_equal [batch.id] * 2, SolidQueue::Job.last(2).map(&:batch_id)
  end

  test "batch id is present inside the block" do
    assert_nil SolidQueue::JobBatch.current_batch_id
    SolidQueue::JobBatch.enqueue(on_finish: BatchCompletionJob) do
      assert_not_nil SolidQueue::JobBatch.current_batch_id
    end
    assert_nil SolidQueue::JobBatch.current_batch_id
  end
end
