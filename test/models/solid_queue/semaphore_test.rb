# frozen_string_literal: true

require "test_helper"

class SolidQueue::SemaphoreTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingByKeyJob < ApplicationJob
    limits_concurrency key: ->(key) { key }

    def perform(key)
    end
  end

  setup do
    @result = JobResult.create!(queue_name: "default")
  end

  test "a job records the semaphore it created, not one deleted after its transaction began" do
    skip "Only MySQL reads a deleted row from the transaction's snapshot" unless SolidQueue::Record.connection.adapter_name.downcase.match?(/mysql|trilogy/)

    NonOverlappingUpdateResultJob.perform_later(@result)
    expired = SolidQueue::Semaphore.sole

    SolidQueue::Record.transaction do
      # Take the transaction's snapshot, as dispatching does when it reads its batch of jobs
      SolidQueue::Job.count

      # Maintenance deletes the expired semaphore from another connection
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection { SolidQueue::Semaphore.where(id: expired.id).delete_all }
      end.join

      job = SolidQueue::Job.enqueue(NonOverlappingUpdateResultJob.new(@result))

      assert job.ready?
      assert_not_equal expired.id, job.acquired_semaphore_id
      assert_equal SolidQueue::Semaphore.lock.find_by!(key: job.concurrency_key).id, job.acquired_semaphore_id
    end
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
            arguments: {},
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

  test "dispatchers with jobs for the same concurrency keys in different order don't deadlock" do
    skip_on_sqlite

    # By job id: one, two, two, one. In batches of two, a dispatcher gets the
    # first two jobs and another one, skipping those, the other two.
    jobs = %w[ one two two one ].map do |key|
      NonOverlappingByKeyJob.set(wait: 1.minute).perform_later(key)
      SolidQueue::Job.last
    end
    travel_to 2.minutes.from_now

    errors = dispatch_in_two_batches_at_once

    assert_empty errors
    assert_equal 0, SolidQueue::ScheduledExecution.count

    # The first job for each key gets the lock
    assert_equal [ :ready, :ready, :blocked, :blocked ], jobs.map { |job| job.reload.status }
  end

  private
    # Two dispatchers, each with a batch of two jobs. Each one, after acquiring
    # its first lock, gives the other the chance to acquire its first one too,
    # so that both hold a lock when they go for the second.
    def dispatch_in_two_batches_at_once
      acquired_first = [ Concurrent::Event.new, Concurrent::Event.new ]

      pause_after_first_lock(acquired_first) do
        dispatchers = 2.times.map do |index|
          Thread.new do
            Thread.current[:dispatcher] = index
            # The second one starts once the first has its batch and its first lock
            acquired_first[0].wait(5.seconds) if index == 1

            SolidQueue::Record.connection_pool.with_connection do
              SolidQueue::ScheduledExecution.dispatch_next_batch(2)
            end

            nil
          rescue => error
            error
          end
        end

        dispatchers.map(&:value).compact
      end
    end

    def pause_after_first_lock(acquired_first)
      original_wait = SolidQueue::Semaphore.method(:wait)

      SolidQueue::Semaphore.define_singleton_method(:wait) do |job|
        original_wait.call(job).tap do
          index = Thread.current[:dispatcher]

          if index && !acquired_first[index].set?
            acquired_first[index].set
            acquired_first[1 - index].wait(2.seconds)
          end
        end
      end

      yield
    ensure
      SolidQueue::Semaphore.define_singleton_method(:wait, original_wait)
    end

    def skip_on_sqlite
      skip "Row-level locking not supported on SQLite" if SolidQueue::Record.connection.adapter_name.downcase.include?("sqlite")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
