require "test_helper"

class SolidQueue::BatchTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.destroy_all
    SolidQueue::Batch.destroy_all
  end

  class BatchWithArgumentsJob < ApplicationJob
    def perform(arg1, arg2)
      Rails.logger.info "Hi #{batch.id}, #{arg1}, #{arg2}!"
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

  test "can add jobs to running batch" do
    batch = SolidQueue::Batch.enqueue(description: "Original", on_finish: BatchCompletionJob) do
      NiceJob.perform_later("first")
    end

    assert batch.enqueued?
    assert_equal 1, batch.jobs.count

    # Add more jobs to the running batch
    batch.enqueue do
      NiceJob.perform_later("second")
    end

    assert_equal 2, batch.jobs.count
  end

  class OtherAdapterCallbackJob < ApplicationJob
    self.queue_adapter = :test

    def perform; end
  end

  test "empty job stays on solid_queue regardless of the app's default adapter" do
    original = ApplicationJob.queue_adapter
    ApplicationJob.queue_adapter = :test

    assert_equal "solid_queue", SolidQueue::Batch::EmptyJob.queue_adapter_name
  ensure
    ApplicationJob.queue_adapter = original
  end

  test "callback jobs enqueue through solid_queue regardless of their class adapter" do
    batch = SolidQueue::Batch.enqueue(on_finish: OtherAdapterCallbackJob) do
      NiceJob.perform_later("world")
    end

    batch.jobs.sole.finished!

    assert batch.reload.finished?
    assert_equal 1, SolidQueue::Job.where(class_name: OtherAdapterCallbackJob.name).count
  end

  test "assigns a reserved active_job_batch_id on create" do
    batch = SolidQueue::Batch.enqueue { NiceJob.perform_later("world") }

    assert batch.active_job_batch_id.present?
  end

  test "cannot enqueue when the batch was finished concurrently" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
    end

    stale = SolidQueue::Batch.find(batch.id)
    SolidQueue::Batch.where(id: batch.id).update_all(finished_at: Time.current)

    assert_raises(SolidQueue::Batch::AlreadyFinished) do
      stale.enqueue { NiceJob.perform_later("another") }
    end
  end

  test "jobs enqueued inside the block join the batch even when instantiated outside" do
    job = NiceJob.new("outside")

    batch = SolidQueue::Batch.enqueue do
      job.enqueue
    end

    assert_equal batch.id, SolidQueue::Job.find_by!(active_job_id: job.job_id).batch_id
  end

  test "jobs instantiated inside the block but enqueued outside do not join the batch" do
    job = nil
    SolidQueue::Batch.enqueue { job = NiceJob.new("inside") }

    job.enqueue

    assert_nil SolidQueue::Job.find_by!(active_job_id: job.job_id).batch_id
  end

  test "in-flight counters do not double count failed jobs" do
    batch = SolidQueue::Batch.enqueue do
      3.times { |i| NiceJob.perform_later(i) }
    end

    jobs = batch.jobs.order(:id).to_a
    jobs.first.failed_with(RuntimeError.new("boom"))

    batch.reload
    assert_equal 3, batch.total_jobs
    assert_equal 2, batch.pending_jobs
    assert_equal 1, batch.failed_jobs
    assert_equal 0, batch.completed_jobs
    assert_equal 33.33, batch.progress_percentage

    jobs.second.finished!

    batch.reload
    assert_equal 1, batch.pending_jobs
    assert_equal 1, batch.completed_jobs
    assert_equal 66.67, batch.progress_percentage
  end

  test "start_batch completes batches whose jobs finished before the batch was started" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
    end

    # Simulate the race where all jobs finish before enqueued_at is committed
    batch.update_columns(enqueued_at: nil)
    batch.jobs.sole.finished!

    assert_not batch.reload.finished?

    batch.send(:start_batch)

    assert batch.reload.finished?
  end

  # Guards the lock-free completion invariants: the CAS conditions on the
  # finishing update, the current-snapshot execution re-check after winning it
  # (load-bearing on PostgreSQL READ COMMITTED, where a blocked CAS re-evaluates
  # NOT EXISTS against a stale snapshot), and completion's atomicity with
  # callback enqueueing. Every interleaving must produce exactly one finish and
  # exactly one set of callbacks — if this fails or flakes, a guard was removed.
  test "concurrent completion checks finish the batch exactly once" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      NiceJob.perform_later("world")
    end

    # Leave the batch as a completion candidate that no check has picked up yet:
    # tracking rows removed without firing their destroy callbacks, as happens
    # with bulk discards.
    SolidQueue::BatchExecution.where(batch_id: batch.id).delete_all

    concurrency = 8
    barrier = Concurrent::CyclicBarrier.new(concurrency)
    threads = concurrency.times.map do
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          barrier.wait
          3.times { SolidQueue::Batch.find(batch.id).check_completion }
        end
      end
    end
    threads.each(&:join)

    batch.reload
    assert batch.finished?
    assert_equal batch.total_jobs, batch.completed_jobs
    assert_equal 1, SolidQueue::Job.where(class_name: "BatchCompletionJob").count

    # And it stays idempotent after the fact
    batch.check_completion
    assert_equal 1, SolidQueue::Job.where(class_name: "BatchCompletionJob").count
  end

  # Guards the increment-before-insert ordering in
  # BatchExecution.create_all_from_jobs: inserting executions first takes a
  # shared lock on the batch row (FK validation) that the increment then
  # upgrades to exclusive, deadlocking concurrent adders on MySQL. If this
  # fails with ActiveRecord::Deadlocked, the statement order was changed.
  test "concurrent adders to the same batch keep exact accounting" do
    batch = SolidQueue::Batch.enqueue { NiceJob.perform_later("seed") }

    concurrency, adds_per_thread = 8, 5
    barrier = Concurrent::CyclicBarrier.new(concurrency)
    errors = Queue.new
    threads = concurrency.times.map do
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          barrier.wait
          adds_per_thread.times do
            SolidQueue::Batch.find(batch.id).enqueue { NiceJob.perform_later("added") }
          rescue => e
            errors << e
          end
        end
      end
    end
    threads.each(&:join)

    raised = []
    raised << errors.pop until errors.empty?
    assert_empty raised

    expected = 1 + concurrency * adds_per_thread
    assert_equal expected, SolidQueue::Job.where(batch_id: batch.id).count
    assert_equal expected, batch.reload.total_jobs
  end

  # Guards the execution re-check after winning the finishing update: on
  # PostgreSQL READ COMMITTED, a completion check that blocked on a concurrent
  # adder's row lock re-evaluates its NOT EXISTS against the original snapshot,
  # so it can win despite the adder's freshly committed executions. Without the
  # re-check, this finishes a batch that still has work.
  test "a completion check that races a concurrent adder does not finish the batch" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) { NiceJob.perform_later("world") }
    job = SolidQueue::Job.where(batch_id: batch.id).sole

    # Make the batch a completion candidate, then re-add the job from a
    # transaction that holds the batch row lock while completion runs.
    SolidQueue::BatchExecution.where(batch_id: batch.id).delete_all

    adder_started = Queue.new
    adder = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          # Same statements, same order as BatchExecution.create_all_from_jobs
          SolidQueue::Batch.where(id: batch.id).unfinished.update_all("total_jobs = total_jobs + 1")
          SolidQueue::BatchExecution.insert_all!([ { batch_id: batch.id, job_id: job.id } ])
          adder_started << true
          sleep 0.5 # hold the row lock so the completion check blocks on it
        end
      end
    end

    adder_started.pop
    SolidQueue::Batch.find(batch.id).check_completion
    adder.join

    assert_not batch.reload.finished?
    assert_equal 1, SolidQueue::BatchExecution.where(batch_id: batch.id).count
  end

  test "start_batch is single-winner: stale instances cannot restart a started batch" do
    batch = SolidQueue::Batch.create!(on_finish: BatchCompletionJob)
    batch.update_columns(enqueued_at: nil, total_jobs: 0)
    SolidQueue::Job.where(batch_id: batch.id).destroy_all

    stale_a = SolidQueue::Batch.find(batch.id)
    stale_b = SolidQueue::Batch.find(batch.id)

    stale_a.start_batch
    started_at = batch.reload.enqueued_at
    assert_equal 1, batch.total_jobs

    travel 1.second do
      stale_b.start_batch
    end

    assert_equal 1, batch.reload.total_jobs
    assert_equal started_at, batch.enqueued_at
  end

  # Batch capture must wrap outside the Rails 7.2+ enqueue deferral: if
  # EnqueueAfterTransactionCommit ends up outermost, capture runs after the
  # batch block has exited and jobs silently miss their batch.
  test "batch capture runs before deferred enqueues" do
    ancestors = ApplicationJob.ancestors
    assert_includes ancestors, ActiveJob::BatchId

    if defined?(ActiveJob::EnqueueAfterTransactionCommit)
      assert_operator ancestors.index(ActiveJob::BatchId), :<, ancestors.index(ActiveJob::EnqueueAfterTransactionCommit)
    end
  end

  test "reused job instances join the currently active batch" do
    job = NiceJob.new("reused")
    batch_a = SolidQueue::Batch.enqueue { job.enqueue }
    batch_b = SolidQueue::Batch.enqueue { job.enqueue }

    assert_equal [ batch_a.id, batch_b.id ],
      SolidQueue::Job.where(active_job_id: job.job_id).order(:id).pluck(:batch_id)
  end

  test "batch accessor reflects a batch assigned after a nil read" do
    job = NiceJob.new("late")
    assert_nil job.batch

    batch = SolidQueue::Batch.enqueue { job.enqueue }

    assert_equal batch.id, job.batch.id
  end

  # Removing a tracking row can fail mid-flight and be swallowed (e.g. SQLite
  # busy inside the finishing transaction), leaving a resolved job with a live
  # row and a batch that can never finish. The sweep repairs exactly that state.
  test "sweep_stalled repairs tracking rows leaked by swallowed removal errors" do
    batch = SolidQueue::Batch.enqueue(on_finish: BatchCompletionJob) do
      2.times { |i| NiceJob.perform_later(i) }
    end

    jobs = batch.jobs.order(:id).to_a
    # Simulate both leak flavors by resolving the jobs without callbacks
    jobs.first.update_columns(finished_at: Time.current)
    SolidQueue::FailedExecution.insert_all!([ { job_id: jobs.second.id, error: { exception_class: "RuntimeError" }.to_json } ])

    assert_equal 2, SolidQueue::BatchExecution.where(batch_id: batch.id).count
    assert_not batch.reload.finished?

    SolidQueue::Batch.sweep_stalled

    batch.reload
    assert batch.finished?
    assert batch.failed?
    assert_equal 1, batch.failed_jobs
    assert_equal 1, batch.completed_jobs
    assert_equal 1, SolidQueue::Job.where(class_name: "BatchCompletionJob").count
  end

  test "sweep_stalled finishes batches whose jobs were bulk discarded" do
    batch = SolidQueue::Batch.enqueue do
      3.times { |i| NiceJob.perform_later(i) }
    end

    # Bulk discards delete jobs without callbacks; the foreign key cascade removes
    # the batch executions, and the sweep picks up the completion.
    SolidQueue::ReadyExecution.discard_all_in_batches

    assert_equal 0, SolidQueue::BatchExecution.count
    assert_not batch.reload.finished?

    SolidQueue::Batch.sweep_stalled(stalled_for: 0.seconds)

    batch.reload
    assert batch.finished?
    assert_equal 0, batch.pending_jobs
    assert_equal 3, batch.completed_jobs
  end

  test "sweep_stalled starts batches whose creating process died before starting them" do
    batch = SolidQueue::Batch.enqueue { NiceJob.perform_later("world") }

    # Simulate a process that crashed after committing jobs but before start_batch
    batch.update_columns(enqueued_at: nil, created_at: 10.minutes.ago)
    batch.jobs.sole.finished!

    assert_not batch.reload.finished?

    SolidQueue::Batch.sweep_stalled

    assert batch.reload.finished?
  end

  test "conflict-discarded jobs count the same for single and bulk enqueues" do
    result1 = JobResult.create!(queue_name: "default", status: "")
    batch1 = SolidQueue::Batch.enqueue do
      DiscardableUpdateResultJob.perform_later(result1, name: "A")
      DiscardableUpdateResultJob.perform_later(result1, name: "B")
    end

    result2 = JobResult.create!(queue_name: "default", status: "")
    batch2 = SolidQueue::Batch.enqueue do
      ActiveJob.perform_all_later([
        DiscardableUpdateResultJob.new(result2, name: "A"),
        DiscardableUpdateResultJob.new(result2, name: "B")
      ])
    end

    assert_equal batch1.reload.total_jobs, batch2.reload.total_jobs
    assert_equal batch1.pending_jobs, batch2.pending_jobs
  end
end
