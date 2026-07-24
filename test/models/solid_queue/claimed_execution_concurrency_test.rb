# frozen_string_literal: true

require "test_helper"

# These tests exercise the real FOR UPDATE serialization in ClaimedExecution's
# finalization, so they run on separate connections/threads and skip on SQLite,
# which has no row-level locking. They follow the same pattern as
# SolidQueue::SemaphoreTest.
class SolidQueue::ClaimedExecutionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
  end

  test "a stale performer that loses the claim lock to pruning does not finish or re-promote a pruned job" do
    skip_on_sqlite

    first_job, claimed_execution, concurrency_key = enqueue_blocked_group

    elapsed = with_winner_holding_claim(claimed_execution,
      in_transaction: ->(locked_claim) do
        first_job.failed_with(SolidQueue::Processes::ProcessPrunedError.new(1.day.ago))
        locked_claim.destroy!
      end,
      after_commit: -> { first_job.unblock_next_blocked_job }) do
      claimed_execution.perform
    end

    assert_operator elapsed, :>=, 0.3, "performer should have blocked on the claim lock (took #{elapsed.round(3)}s)"
    assert first_job.reload.failed?
    assert_not first_job.finished?
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: concurrency_key).value
  end

  test "a stale failing performer that loses the claim lock to pruning does not double-finalize" do
    skip_on_sqlite

    first_job, claimed_execution, concurrency_key = enqueue_blocked_group(exception: RuntimeError)

    elapsed = with_winner_holding_claim(claimed_execution,
      in_transaction: ->(locked_claim) do
        first_job.failed_with(SolidQueue::Processes::ProcessPrunedError.new(1.day.ago))
        locked_claim.destroy!
      end,
      after_commit: -> { first_job.unblock_next_blocked_job }) do
      assert_raises(RuntimeError) { claimed_execution.perform }
    end

    assert_operator elapsed, :>=, 0.3, "performer should have blocked on the claim lock (took #{elapsed.round(3)}s)"
    assert first_job.reload.failed?
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
    assert_equal 1, SolidQueue::FailedExecution.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: concurrency_key).value
  end

  test "a stale release that loses the claim lock to pruning does not re-dispatch a pruned job" do
    skip_on_sqlite

    first_job, claimed_execution, concurrency_key = enqueue_blocked_group

    elapsed = with_winner_holding_claim(claimed_execution,
      in_transaction: ->(locked_claim) do
        first_job.failed_with(SolidQueue::Processes::ProcessPrunedError.new(1.day.ago))
        locked_claim.destroy!
      end,
      after_commit: -> { first_job.unblock_next_blocked_job }) do
      claimed_execution.release
    end

    assert_operator elapsed, :>=, 0.3, "release should have blocked on the claim lock (took #{elapsed.round(3)}s)"
    assert first_job.reload.failed?
    assert_not first_job.ready?
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: concurrency_key).value
  end

  test "pruning that loses the claim lock to a finishing performer does not fail a finished job" do
    skip_on_sqlite

    first_job, claimed_execution, concurrency_key = enqueue_blocked_group

    elapsed = with_winner_holding_claim(claimed_execution,
      in_transaction: ->(locked_claim) do
        first_job.finished!
        locked_claim.destroy!
      end,
      after_commit: -> { first_job.unblock_next_blocked_job }) do
      @process.prune
    end

    assert_operator elapsed, :>=, 0.3, "pruning should have blocked on the claim lock (took #{elapsed.round(3)}s)"
    assert first_job.reload.finished?
    assert_not first_job.failed?
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
    assert_equal 0, SolidQueue::FailedExecution.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: concurrency_key).value
  end

  test "finalizing a claim does not deadlock a concurrent blocked-job release when skip_locked is off" do
    skip_on_sqlite

    with_skip_locked(false) do
      first_job, claimed_execution, concurrency_key = enqueue_blocked_group
      blocked_execution = SolidQueue::BlockedExecution.first

      holding_blocked_row = Concurrent::Event.new
      release_blocked_row = Concurrent::Event.new

      # Mimic the normal release path's lock order: lock the blocked row first,
      # then contend for the semaphore. Held open so finalize must run alongside it.
      releaser = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          SolidQueue::Record.transaction do
            SolidQueue::BlockedExecution.where(id: blocked_execution.id).lock.first
            holding_blocked_row.set
            release_blocked_row.wait(5)
            SolidQueue::Semaphore.where(key: concurrency_key).lock.first
          end
        end
      end

      holding_blocked_row.wait(5)

      # finalize releases the concurrency lock and commits before it tries to
      # release the next blocked job, so it never holds the semaphore lock while
      # waiting on the blocked row. Releasing the blocked job inside the claim
      # transaction would reverse the lock order and could deadlock.
      assert_nothing_raised do
        Timeout.timeout(10) do
          finisher = Thread.new do
            SolidQueue::Record.connection_pool.with_connection do
              claimed_execution.send(:finished)
            end
          end

          # Give finalize time to commit its semaphore signal, then let the
          # releaser reach for the semaphore.
          sleep 0.5
          release_blocked_row.set
          finisher.join(10)
        end
      end

      releaser.join(10)

      assert first_job.reload.finished?
      assert_equal 0, SolidQueue::ClaimedExecution.count
    end
  end

  private
    # Enqueues three concurrency-limited jobs over the same key. The first is
    # claimed; the other two are blocked. Returns the first job, its claimed
    # execution, and the shared concurrency key.
    def enqueue_blocked_group(exception: nil)
      job_result = JobResult.create!(queue_name: "default", status: "")
      first_active_job = NonOverlappingUpdateResultJob.perform_later(job_result, name: "A", exception: exception)
      NonOverlappingUpdateResultJob.perform_later(job_result, name: "B")
      NonOverlappingUpdateResultJob.perform_later(job_result, name: "C")

      first_job = SolidQueue::Job.find_by!(active_job_id: first_active_job.job_id)
      claimed_execution = claim_first_job(first_job)

      [ first_job, claimed_execution, first_job.concurrency_key ]
    end

    def claim_first_job(job)
      SolidQueue::ReadyExecution.claim(job.queue_name, 1, @process.id)
      SolidQueue::ClaimedExecution.find_by!(job_id: job.id)
    end

    # Runs the given block (the stale worker's action) while a separate connection
    # holds the claim's FOR UPDATE lock, then finishes the claim first and commits.
    # The stale worker must block on the lock and, once it resumes, find the claim
    # gone. Returns how long the stale worker was blocked.
    def with_winner_holding_claim(claimed_execution, in_transaction:, after_commit: nil)
      claim_locked = Concurrent::Event.new

      winner = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          SolidQueue::Record.transaction do
            locked_claim = SolidQueue::ClaimedExecution.unscoped.lock.find_by(id: claimed_execution.id)
            claim_locked.set
            sleep 0.5
            in_transaction.call(locked_claim)
          end

          after_commit&.call
        end
      end

      claim_locked.wait(5)
      sleep 0.1

      started_at = monotonic_now
      yield
      elapsed = monotonic_now - started_at

      winner.join(5)
      elapsed
    end

    def with_skip_locked(value)
      previous = SolidQueue.use_skip_locked
      SolidQueue.use_skip_locked = value
      yield
    ensure
      SolidQueue.use_skip_locked = previous
    end

    def skip_on_sqlite
      skip "Row-level locking not supported on SQLite" if SolidQueue::Record.connection.adapter_name.downcase.include?("sqlite")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
