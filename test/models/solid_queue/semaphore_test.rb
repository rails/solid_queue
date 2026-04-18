# frozen_string_literal: true

require "test_helper"

class SolidQueue::SemaphoreTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @result = JobResult.create!(queue_name: "default")
  end

  test "wait acquires a row lock that blocks concurrent signal" do
    skip_on_sqlite

    # Enqueue first job to create semaphore with value=0
    NonOverlappingUpdateResultJob.perform_later(@result)
    concurrency_key = SolidQueue::Job.last.concurrency_key
    assert_equal 0, SolidQueue::Semaphore.find_by(key: concurrency_key).value

    lock_held = Concurrent::Event.new

    # Background thread: holds a FOR UPDATE lock on the semaphore row
    locker = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          SolidQueue::Semaphore.where(key: concurrency_key).lock.first
          lock_held.set
          sleep 1
        end
      end
    end

    lock_held.wait(5)
    sleep 0.1

    # Main thread: this UPDATE should block until the locker's transaction commits
    start = monotonic_now
    SolidQueue::Semaphore.where(key: concurrency_key).update_all("value = value + 1")
    elapsed = monotonic_now - start

    locker.join(5)

    assert elapsed >= 0.5, "UPDATE should have been blocked by FOR UPDATE lock (took #{elapsed.round(3)}s)"
    assert_equal 1, SolidQueue::Semaphore.find_by(key: concurrency_key).value
  end

  test "blocked execution created during enqueue is visible to release_one after signal" do
    skip_on_sqlite

    # Enqueue first job to create semaphore with value=0
    NonOverlappingUpdateResultJob.perform_later(@result)
    job_a = SolidQueue::Job.last
    concurrency_key = job_a.concurrency_key
    assert_equal 0, SolidQueue::Semaphore.find_by(key: concurrency_key).value

    lock_held = Concurrent::Event.new

    # Background thread: simulates the enqueue path for a second job.
    # Locks the semaphore row (as the code does), creates a BlockedExecution,
    # then holds the transaction open to simulate the window where the race occurs.
    enqueue_thread = Thread.new do
      SolidQueue::Record.connection_pool.with_connection do
        SolidQueue::Record.transaction do
          # Lock the semaphore (same as Semaphore::Proxy#wait)
          SolidQueue::Semaphore.where(key: concurrency_key).lock.first

          # Create job and blocked execution bypassing after_create callbacks
          # to avoid re-entering Semaphore.wait
          uuid = SecureRandom.uuid
          SolidQueue::Job.insert({
            queue_name: "default",
            class_name: "NonOverlappingUpdateResultJob",
            concurrency_key: concurrency_key,
            active_job_id: uuid,
            arguments: "{}",
            scheduled_at: Time.current
          })
          job_b_id = SolidQueue::Job.where(active_job_id: uuid).pick(:id)

          SolidQueue::BlockedExecution.insert({
            job_id: job_b_id,
            queue_name: "default",
            concurrency_key: concurrency_key,
            expires_at: SolidQueue.default_concurrency_control_period.from_now,
            priority: 0
          })

          lock_held.set

          # Hold the transaction open so the signal path must wait
          sleep 1
        end
      end
    end

    lock_held.wait(5)
    sleep 0.1

    # Main thread: simulates job_a finishing — signal + release_one.
    # The signal UPDATE will block until the enqueue transaction commits,
    # guaranteeing the BlockedExecution is visible to release_one.
    assert SolidQueue::Semaphore.signal(job_a)
    assert SolidQueue::BlockedExecution.release_one(concurrency_key),
      "release_one should find the BlockedExecution created by the concurrent enqueue"

    enqueue_thread.join(5)

    assert_equal 0, SolidQueue::BlockedExecution.where(concurrency_key: concurrency_key).count
  end

  private
    def skip_on_sqlite
      skip "Row-level locking not supported on SQLite" if SolidQueue::Record.connection.adapter_name.downcase.include?("sqlite")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
