# frozen_string_literal: true

require "test_helper"

class BatchLifecycleTest < ActiveSupport::TestCase
  setup do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3)
    @dispatcher = SolidQueue::Dispatcher.new(batch_size: 10, polling_interval: 0.2)
  end

  teardown do
    @worker.stop
    @dispatcher.stop

    JobBuffer.clear

    SolidQueue::Job.destroy_all
    SolidQueue::JobBatch.destroy_all
  end

  class BatchOnSuccessJob < ApplicationJob
    queue_as :background

    def perform(batch, custom_message = "")
      JobBuffer.add "#{custom_message}: #{batch.jobs.size} jobs succeeded!"
    end
  end

  class AddsMoreJobsJob < ApplicationJob
    queue_as :background

    def perform
      batch.enqueue do
        AddToBufferJob.perform_later "added from inside 1"
        AddToBufferJob.perform_later "added from inside 2"
        SolidQueue::JobBatch.enqueue do
          AddToBufferJob.perform_later "added from inside 3"
        end
      end
    end
  end

  test "nested batches finish from the inside out" do
    batch2 = batch3 = batch4 = nil
    batch1 = SolidQueue::JobBatch.enqueue(on_success: BatchOnSuccessJob.new("3")) do
      batch2 = SolidQueue::JobBatch.enqueue(on_success: BatchOnSuccessJob.new("2")) do
        batch3 = SolidQueue::JobBatch.enqueue(on_success: BatchOnSuccessJob.new("1")) { }
        batch4 = SolidQueue::JobBatch.enqueue(on_success: BatchOnSuccessJob.new("1.1")) { }
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_job_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal [ "1: 0 jobs succeeded!", "1.1: 0 jobs succeeded!", "2: 2 jobs succeeded!", "3: 1 jobs succeeded!" ], JobBuffer.values
    assert_equal 4, SolidQueue::JobBatch.finished.count
    assert_equal batch1.reload.finished_at > batch2.reload.finished_at, true
    assert_equal batch2.finished_at > batch3.reload.finished_at, true
    assert_equal batch2.finished_at > batch4.reload.finished_at, true
  end

  test "all jobs are run, including jobs enqueued inside of other jobs" do
    SolidQueue::JobBatch.enqueue do
      AddToBufferJob.perform_later "hey"
      SolidQueue::JobBatch.enqueue do
        AddToBufferJob.perform_later "ho"
        AddsMoreJobsJob.perform_later
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_job_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal [ "added from inside 1", "added from inside 2", "added from inside 3", "hey", "ho" ], JobBuffer.values.sort
    assert_equal 3, SolidQueue::JobBatch.finished.count
  end
end
