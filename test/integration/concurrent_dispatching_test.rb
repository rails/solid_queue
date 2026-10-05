# frozen_string_literal: true

require "test_helper"

class ConcurrentDispatchingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingJob < ApplicationJob
    limits_concurrency key: ->(key) { key }

    def perform(key)
    end
  end

  setup do
    # SQLite allows a single writer at a time, so two dispatchers never hold
    # locks at once.
    skip "SQLite serializes all writes" if SolidQueue::Record.connection_pool.db_config.adapter == "sqlite3"

    @original_wait = SolidQueue::Semaphore.method(:wait)
  end

  teardown do
    SolidQueue::Semaphore.define_singleton_method(:wait, @original_wait) if @original_wait
  end

  test "dispatchers with jobs for the same concurrency keys in different order don't deadlock" do
    # By job id: one, two, two, one. In batches of two, a dispatcher gets the
    # first two jobs and another one, skipping those, the other two.
    jobs = %w[ one two two one ].map do |key|
      NonOverlappingJob.set(wait: 1.minute).perform_later(key)
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
      pause_after_first_lock(acquired_first)

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

    def pause_after_first_lock(acquired_first)
      original_wait = @original_wait

      SolidQueue::Semaphore.define_singleton_method(:wait) do |job|
        original_wait.call(job).tap do
          index = Thread.current[:dispatcher]

          if index && !acquired_first[index].set?
            acquired_first[index].set
            acquired_first[1 - index].wait(2.seconds)
          end
        end
      end
    end
end
