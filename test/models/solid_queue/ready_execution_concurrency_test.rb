# frozen_string_literal: true

require "test_helper"

# These tests exercise the lock ReadyExecution.claim takes on the claiming
# process, so they run on separate connections/threads and skip on SQLite,
# which has no row-level locking. They follow the same pattern as
# SolidQueue::ClaimedExecutionConcurrencyTest.
class SolidQueue::ReadyExecutionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
    @job = SolidQueue::Job.find_by!(active_job_id: AddToBufferJob.perform_later(1).job_id)
  end

  [ true, false ].each do |skip_locked|
    test "deregistering a process waits for its claim and releases it (use_skip_locked: #{skip_locked})" do
      skip_on_sqlite

      with_skip_locked(skip_locked) do
        elapsed = with_claim_in_progress do
          @process.deregister
        end

        assert_operator elapsed, :>=, 0.3, "deregister should have blocked on the claim (took #{elapsed.round(3)}s)"
        assert_not SolidQueue::Process.exists?(@process.id)
        assert_equal 0, SolidQueue::ClaimedExecution.count
        assert @job.reload.ready?
      end
    end
  end

  test "claiming doesn't deadlock with deregistering another process that releases its claims" do
    skip_on_sqlite

    other = SolidQueue::Process.register(kind: "Worker", pid: 43, name: "worker-456")
    10.times { |i| AddToBufferJob.perform_later(i) }
    SolidQueue::ReadyExecution.claim("*", 5, other.id)

    errors = Concurrent::Array.new
    start = Concurrent::Event.new

    claimers = 3.times.map do
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          start.wait(5)
          5.times { SolidQueue::ReadyExecution.claim("*", 1, @process.id) }
        end
      rescue => error
        errors << error
      end
    end

    deregisterer = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        start.wait(5)
        other.reload.deregister
      end
    rescue => error
      errors << error
    end

    start.set
    [ *claimers, deregisterer ].each { |thread| assert thread.join(10), "a thread got stuck" }

    assert_empty errors
    assert_equal 0, SolidQueue::ClaimedExecution.where(process_id: other.id).count
    assert_equal 11, SolidQueue::ReadyExecution.count + SolidQueue::ClaimedExecution.where(process_id: @process.id).count
  end

  private
    # Claims @job on a separate connection and holds the claim's transaction open
    # while the given block runs, then commits. Returns how long the block took.
    def with_claim_in_progress
      claimed = Concurrent::Event.new
      claims = nil

      claimer = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          SolidQueue::Record.transaction do
            claims = SolidQueue::ReadyExecution.claim(@job.queue_name, 1, @process.id)
            claimed.set
            sleep 0.5
          end
        end
      end

      assert claimed.wait(5), "the claim should have started"
      assert_equal [ @job.id ], claims.map(&:job_id)

      started_at = monotonic_now
      yield
      elapsed = monotonic_now - started_at

      assert claimer.join(5), "the claim should have finished"
      elapsed
    ensure
      claimer&.join(5)
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
