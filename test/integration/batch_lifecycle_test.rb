# frozen_string_literal: true

require "test_helper"

class BatchLifecycleTest < ActiveSupport::TestCase
  FailingJobError = Class.new(RuntimeError)

  def assert_finished_in_order(*finishables)
    finishables.each_cons(2) do |finished1, finished2|
      assert_equal finished1.finished_at < finished2.finished_at, true
    end
  end

  def job!(active_job)
    SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
  end

  setup do
    @_on_thread_error = SolidQueue.on_thread_error
    SolidQueue.on_thread_error = silent_on_thread_error_for([ FailingJobError ], @_on_thread_error)
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3)
    @dispatcher = SolidQueue::Dispatcher.new(batch_size: 10, polling_interval: 0.2)
  end

  teardown do
    SolidQueue.on_thread_error = @_on_thread_error
    @worker.stop
    @dispatcher.stop

    JobBuffer.clear

    SolidQueue::Job.destroy_all
    SolidQueue::Batch.destroy_all

    ApplicationJob.enqueue_after_transaction_commit = false if defined?(ApplicationJob.enqueue_after_transaction_commit)
    SolidQueue.preserve_finished_jobs = true
  end

  class BatchOnSuccessJob < ApplicationJob
    queue_as :background

    def perform(batch, custom_message = "")
      JobBuffer.add "#{custom_message}: #{batch.completed_jobs} jobs succeeded!"
    end
  end

  class BatchOnFailureJob < ApplicationJob
    queue_as :background

    def perform(batch, custom_message = "")
      JobBuffer.add "#{custom_message}: #{batch.failed_jobs} jobs failed!"
    end
  end

  class FailingJob < ApplicationJob
    queue_as :background

    retry_on FailingJobError, attempts: 3, wait: 0.1.seconds

    def perform
      raise FailingJobError, "Failing job"
    end
  end

  class DiscardingJob < ApplicationJob
    queue_as :background

    discard_on FailingJobError

    def perform
      raise FailingJobError, "Failing job"
    end
  end

  class AddsMoreJobsJob < ApplicationJob
    queue_as :background

    def perform
      batch.enqueue do
        AddToBufferJob.perform_later "added from inside 1"
        AddToBufferJob.perform_later "added from inside 2"
        SolidQueue::Batch.enqueue do
          AddToBufferJob.perform_later "added from inside 3"
        end
      end
    end
  end

  test "empty batches never finish" do
    # `enqueue_after_transaction_commit` makes it difficult to tell if a batch is empty, or if the
    #   jobs are waiting to be run after commit.
    # If we could tell deterministically, we could enqueue an EmptyJob to make sure the batches
    #   don't hang forever.
    SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("3")) do
      SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("2")) do
        SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("1")) { }
        SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("1.1")) { }
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(1.second)

    assert_equal [], JobBuffer.values
    assert_equal 4, SolidQueue::Batch.pending.count
  end

  test "nested batches finish from the inside out" do
    batch2 = batch3 = batch4 = nil
    batch1 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("3")) do
      SolidQueue::Batch::EmptyJob.perform_later
      batch2 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("2")) do
        SolidQueue::Batch::EmptyJob.perform_later
        batch3 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("1")) do
          SolidQueue::Batch::EmptyJob.perform_later
        end
        batch4 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("1.1")) do
          SolidQueue::Batch::EmptyJob.perform_later
        end
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(1.second)

    expected_values = [ "1: 1 jobs succeeded!", "1.1: 1 jobs succeeded!", "2: 1 jobs succeeded!", "3: 1 jobs succeeded!" ]
    assert_equal expected_values.sort, JobBuffer.values.sort
    assert_equal 4, SolidQueue::Batch.finished.count
    assert_finished_in_order(batch4.reload, batch2.reload, batch1.reload)
    assert_finished_in_order(batch3.reload, batch2, batch1)
  end

  test "all jobs are run, including jobs enqueued inside of other jobs" do
    batch2 = nil
    job1 = job2 = job3 = nil
    batch1 = SolidQueue::Batch.enqueue do
      job1 = AddToBufferJob.perform_later "hey"
      batch2 = SolidQueue::Batch.enqueue do
        job2 = AddToBufferJob.perform_later "ho"
        job3 = AddsMoreJobsJob.perform_later
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)

    assert_equal [ "added from inside 1", "added from inside 2", "added from inside 3", "hey", "ho" ], JobBuffer.values.sort
    assert_equal 3, SolidQueue::Batch.finished.count
    assert_finished_in_order(batch2.reload, batch1.reload)
    assert_finished_in_order(job!(job3), batch2)
    assert_finished_in_order(job!(job2), batch2)
    assert_finished_in_order(job!(job1), batch1)
  end

  test "when self.enqueue_after_transaction_commit = true" do
    skip if Rails::VERSION::MAJOR == 7 && Rails::VERSION::MINOR == 1

    ApplicationJob.enqueue_after_transaction_commit = true
    batch1 = batch2 = batch3 = nil
    job1 = job2 = job3 = nil
    JobResult.transaction do
      JobResult.create!(queue_name: "default", status: "")

      batch1 = SolidQueue::Batch.enqueue do
        job1 = AddToBufferJob.perform_later "hey"
        JobResult.transaction(requires_new: true) do
          JobResult.create!(queue_name: "default", status: "")
          batch2 = SolidQueue::Batch.enqueue do
            job2 = AddToBufferJob.perform_later "ho"
            batch3 = SolidQueue::Batch.enqueue do
              job3 = AddToBufferJob.perform_later "let's go"
            end
          end
        end
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)

    assert_equal [ "hey", "ho", "let's go" ], JobBuffer.values.sort
    assert_equal 3, SolidQueue::Batch.finished.count
    assert_equal 3, SolidQueue::Job.finished.count
    assert_equal 3, SolidQueue::Job.count
    assert_finished_in_order(batch3.reload, batch2.reload, batch1.reload)
    assert_finished_in_order(job!(job3), batch3)
    assert_finished_in_order(job!(job2), batch2)
    assert_finished_in_order(job!(job1), batch1)
  end

  test "failed jobs fire properly" do
    batch2 = nil
    batch1 = SolidQueue::Batch.enqueue(on_failure: BatchOnFailureJob.new("0")) do
      FailingJob.perform_later
      batch2 = SolidQueue::Batch.enqueue(on_failure: BatchOnFailureJob.new("1")) do
        FailingJob.perform_later
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(3.seconds)
    wait_for_jobs_to_finish_for(1.second)

    job_batch1 = SolidQueue::Batch.find_by(batch_id: batch1.batch_id)
    job_batch2 = SolidQueue::Batch.find_by(batch_id: batch2.batch_id)

    assert_equal 2, SolidQueue::Batch.count
    assert_equal 2, SolidQueue::Batch.finished.count

    assert_equal 3, job_batch1.total_jobs  # 1 original + 2 retries
    assert_equal 1, job_batch1.failed_jobs  # Final failure
    assert_equal 2, job_batch1.completed_jobs  # 2 retries marked as "finished"
    assert_equal 0, job_batch1.pending_jobs

    assert_equal 3, job_batch2.total_jobs  # 1 original + 2 retries
    assert_equal 1, job_batch2.failed_jobs  # Final failure
    assert_equal 2, job_batch2.completed_jobs  # 2 retries marked as "finished"
    assert_equal 0, job_batch2.pending_jobs

    assert_equal [ "failed", "failed" ].sort, SolidQueue::Batch.all.pluck(:status)
    assert_equal [ "0: 1 jobs failed!", "1: 1 jobs failed!" ], JobBuffer.values.sort
    assert_finished_in_order(batch2.reload, batch1.reload)
  end

  test "executes the same with perform_all_later as it does a normal enqueue" do
    batch2 = nil
    batch1 = SolidQueue::Batch.enqueue do
      ActiveJob.perform_all_later([ FailingJob.new, FailingJob.new ])
      batch2 = SolidQueue::Batch.enqueue do
        ActiveJob.perform_all_later([ AddToBufferJob.new("ok"), AddToBufferJob.new("ok2") ])
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(3.seconds)
    wait_for_jobs_to_finish_for(1.second)

    assert_equal 6, batch1.reload.jobs.count
    assert_equal 6, batch1.total_jobs
    assert_equal 2, SolidQueue::Batch.finished.count
    assert_equal "failed", batch1.status
    assert_equal 2, batch2.reload.jobs.count
    assert_equal 2, batch2.total_jobs
    assert_equal "completed", batch2.status
  end

  test "discarded jobs fire properly" do
    batch2 = nil
    batch1 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("0")) do
      DiscardingJob.perform_later
      batch2 = SolidQueue::Batch.enqueue(on_success: BatchOnSuccessJob.new("1")) do
        DiscardingJob.perform_later
      end
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(3.seconds)
    wait_for_jobs_to_finish_for(1.second)

    job_batch1 = SolidQueue::Batch.find_by(batch_id: batch1.batch_id)
    job_batch2 = SolidQueue::Batch.find_by(batch_id: batch2.batch_id)

    assert_equal 2, SolidQueue::Batch.count
    assert_equal 2, SolidQueue::Batch.finished.count

    assert_equal 1, job_batch1.total_jobs
    assert_equal 0, job_batch1.failed_jobs
    assert_equal 1, job_batch1.completed_jobs
    assert_equal 0, job_batch1.pending_jobs

    assert_equal 1, job_batch2.total_jobs
    assert_equal 0, job_batch2.failed_jobs
    assert_equal 1, job_batch2.completed_jobs
    assert_equal 0, job_batch2.pending_jobs

    assert_equal [ "completed", "completed" ].sort, SolidQueue::Batch.all.pluck(:status)
    assert_equal [ "0: 1 jobs succeeded!", "1: 1 jobs succeeded!" ], JobBuffer.values.sort
    assert_finished_in_order(batch2.reload, batch1.reload)
  end

  test "preserve_finished_jobs = false" do
    SolidQueue.preserve_finished_jobs = false
    batch1 = SolidQueue::Batch.enqueue do
      AddToBufferJob.perform_later "hey"
    end

    assert_equal false, batch1.reload.finished?
    assert_equal 1, SolidQueue::Job.count
    assert_equal 0, SolidQueue::Job.finished.count

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal true, batch1.reload.finished?
    assert_equal 0, SolidQueue::Job.count
  end

  test "batch interface" do
    batch = SolidQueue::Batch.enqueue(
      metadata: { source: "test", priority: "high", user_id: 123 },
      on_finish: OnFinishJob,
      on_success: OnSuccessJob,
      on_failure: OnFailureJob
    ) do
      AddToBufferJob.perform_later "hey"
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(1.second)

    assert_equal [ "Hi finish #{batch.batch_id}!", "Hi success #{batch.batch_id}!", "hey" ].sort, JobBuffer.values.sort
    assert_equal 1, batch.reload.completed_jobs
    assert_equal 0, batch.failed_jobs
    assert_equal 0, batch.pending_jobs
    assert_equal 1, batch.total_jobs
  end

  class OnFinishJob < ApplicationJob
    queue_as :background

    def perform(batch)
      JobBuffer.add "Hi finish #{batch.batch_id}!"
    end
  end

  class OnSuccessJob < ApplicationJob
    queue_as :background

    def perform(batch)
      JobBuffer.add "Hi success #{batch.batch_id}!"
    end
  end

  class OnFailureJob < ApplicationJob
    queue_as :background

    def perform(batch)
      JobBuffer.add "Hi failure #{batch.batch_id}!"
    end
  end
end
