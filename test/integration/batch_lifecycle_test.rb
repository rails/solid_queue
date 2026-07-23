# frozen_string_literal: true

require "test_helper"

class BatchLifecycleTest < ActiveSupport::TestCase
  FailingJobError = Class.new(RuntimeError)

  setup do
    @_on_thread_error = SolidQueue.on_thread_error
    SolidQueue.on_thread_error = silent_on_thread_error_for([ FailingJobError ], @_on_thread_error)
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3)
    @dispatcher = SolidQueue::Dispatcher.new(batch_size: 10, polling_interval: 0.2)
    SolidQueue::Batch::EmptyJob.queue_as "background"
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
    SolidQueue::Batch::EmptyJob.queue_as "default"
  end

  class BatchOnSuccessJob < ApplicationJob
    queue_as :background

    def perform(custom_message = "")
      JobBuffer.add "#{custom_message}: #{batch.completed_jobs} jobs succeeded!"
    end
  end

  class BatchOnFailureJob < ApplicationJob
    queue_as :background

    def perform(custom_message = "")
      JobBuffer.add "#{custom_message}: #{batch.failed_jobs} jobs failed!"
    end
  end

  class FailFastJob < ApplicationJob
    queue_as :background

    def perform
      raise FailingJobError, "Failing job"
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

  test "empty batches fire callbacks" do
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

    expected_values = [ "1: 1 jobs succeeded!", "1.1: 1 jobs succeeded!", "2: 1 jobs succeeded!", "3: 1 jobs succeeded!" ]
    assert_equal expected_values.sort, JobBuffer.values.sort
    assert_equal 4, SolidQueue::Batch.finished.count
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
    assert_finished_in_order(job!(job3), batch2.reload)
    assert_finished_in_order(job!(job2), batch2)
    assert_finished_in_order(job!(job1), batch1.reload)
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

    wait_for_batches_to_finish_for(5.seconds)

    jobs = batch_jobs(batch1, batch2, batch3)
    assert_equal [ "hey", "ho", "let's go" ], JobBuffer.values.sort
    assert_equal 3, SolidQueue::Batch.finished.count
    assert_equal 3, jobs.finished.count
    assert_equal 3, jobs.count
    assert_finished_in_order(job!(job3), batch3.reload)
    assert_finished_in_order(job!(job2), batch2.reload)
    assert_finished_in_order(job!(job1), batch1.reload)
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

    wait_for_batches_to_finish_for(5.seconds)
    wait_for_jobs_to_finish_for(5.second)

    job_batch1 = SolidQueue::Batch.find_by(id: batch1.id)
    job_batch2 = SolidQueue::Batch.find_by(id: batch2.id)

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

    assert_equal [ true, true ].sort, SolidQueue::Batch.all.map(&:failed?)
    assert_equal [ "0: 1 jobs failed!", "1: 1 jobs failed!" ], JobBuffer.values.sort
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

    wait_for_batches_to_finish_for(5.seconds)
    wait_for_jobs_to_finish_for(5.second)

    assert_equal 6, batch1.reload.jobs.count
    assert_equal 6, batch1.total_jobs
    assert_equal 2, SolidQueue::Batch.finished.count
    assert_equal true, batch1.failed?
    assert_equal 2, batch2.reload.jobs.count
    assert_equal 2, batch2.total_jobs
    assert_equal true, batch2.succeeded?
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

    wait_for_batches_to_finish_for(5.seconds)
    wait_for_jobs_to_finish_for(5.second)

    job_batch1 = SolidQueue::Batch.find_by(id: batch1.id)
    job_batch2 = SolidQueue::Batch.find_by(id: batch2.id)

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

    assert_equal [ true, true ].sort, SolidQueue::Batch.all.map(&:succeeded?)
    assert_equal [ "0: 1 jobs succeeded!", "1: 1 jobs succeeded!" ], JobBuffer.values.sort
  end

  test "preserve_finished_jobs = false" do
    SolidQueue.preserve_finished_jobs = false
    batch1 = SolidQueue::Batch.enqueue do
      AddToBufferJob.perform_later "hey"
    end

    assert_equal false, batch1.reload.finished?
    assert_equal 1, batch1.jobs.count
    assert_equal 0, batch1.jobs.finished.count

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(5.seconds)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal true, batch1.reload.finished?
    assert_equal 0, SolidQueue::Job.count
  end

  test "batch interface" do
    batch = SolidQueue::Batch.enqueue(
      on_finish: OnFinishJob,
      on_success: OnSuccessJob,
      on_failure: OnFailureJob,
      source: "test", priority: "high", user_id: 123
    ) do
      AddToBufferJob.perform_later "hey"
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(2.seconds)
    wait_for_jobs_to_finish_for(1.second)

    assert_equal [ "Hi finish #{batch.id}!", "Hi success #{batch.id}!", "hey" ].sort, JobBuffer.values.sort
    assert_equal 1, batch.reload.completed_jobs
    assert_equal 0, batch.failed_jobs
    assert_equal 0, batch.pending_jobs
    assert_equal 1, batch.total_jobs
  end

  test "clear finished batches after configured period" do
    5.times { SolidQueue::Batch.enqueue { AddToBufferJob.perform_later "hey" } }
    5.times { SolidQueue::Batch.enqueue { FailFastJob.perform_later } }

    assert_no_difference -> { SolidQueue::Batch.count } do
      SolidQueue::Batch.clear_finished_in_batches
    end

    @dispatcher.start
    @worker.start

    wait_for_batches_to_finish_for(5.seconds)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_no_difference -> { SolidQueue::Batch.count } do
      SolidQueue::Batch.clear_finished_in_batches
    end

    travel_to 3.days.from_now

    assert_difference -> { SolidQueue::Batch.count }, -5 do
      SolidQueue::Batch.clear_finished_in_batches
    end

    assert_equal 5, SolidQueue::Batch.count
    assert_equal 5, SolidQueue::Batch.failed.count
  end

  class OnFinishJob < ApplicationJob
    queue_as :background

    def perform
      JobBuffer.add "Hi finish #{batch.id}!"
    end
  end

  class OnSuccessJob < ApplicationJob
    queue_as :background

    def perform
      JobBuffer.add "Hi success #{batch.id}!"
    end
  end

  class OnFailureJob < ApplicationJob
    queue_as :background

    def perform
      JobBuffer.add "Hi failure #{batch.id}!"
    end
  end

  def assert_finished_in_order(*finishables)
    finishables.each_cons(2) do |finished1, finished2|
      assert_equal finished1.finished_at < finished2.finished_at, true
    end
  end

  def job!(active_job)
    SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
  end

  def batch_jobs(*batches)
    SolidQueue::Job.where(batch_id: batches.map(&:id))
  end
end
