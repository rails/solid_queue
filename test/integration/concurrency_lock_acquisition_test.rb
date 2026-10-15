# frozen_string_literal: true

require "test_helper"

class ConcurrencyLockAcquisitionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingJob < ApplicationJob
    # Enqueued inside the transaction, which is what this is about.
    # Rails 7.2 takes :never rather than false.
    self.enqueue_after_transaction_commit = Rails.version.start_with?("7.2") ? :never : false if respond_to?(:enqueue_after_transaction_commit=)

    limits_concurrency key: ->(key) { key }

    def perform(key)
    end
  end

  setup do
    # SQLite allows a single writer at a time, so any enqueue waits for any open
    # write transaction, concurrency controls or not.
    skip "SQLite serializes all writes" if SolidQueue::Record.connection_pool.db_config.adapter == "sqlite3"
  end

  test "a job enqueued inside a transaction holds its concurrency lock until the transaction ends" do
    assert_not completes_while_transaction_is_open?(acquire: :on_enqueue) {
      NonOverlappingJob.perform_later("shared")
    }
  end

  test "a job leaving its concurrency lock to the dispatcher doesn't hold it in the transaction" do
    assert completes_while_transaction_is_open?(acquire: :outside_transaction) {
      NonOverlappingJob.perform_later("shared")
    }
  end

  test "a worker signalling the semaphore waits for a transaction whose enqueue was blocked" do
    running = enqueue_running_job

    assert_not completes_while_transaction_is_open?(acquire: :on_enqueue) {
      SolidQueue::Semaphore.signal(running)
    }
  end

  test "a worker signalling the semaphore doesn't wait for a transaction that left the lock to the dispatcher" do
    running = enqueue_running_job

    assert completes_while_transaction_is_open?(acquire: :outside_transaction) {
      SolidQueue::Semaphore.signal(running)
    }
  end

  test "transactions enqueueing jobs for two keys in opposite order deadlock" do
    errors = enqueue_in_opposite_orders(acquire: :on_enqueue)

    assert_equal 1, errors.size
    assert_kind_of SolidQueue::Job::EnqueueError, errors.first
    assert_kind_of ActiveRecord::Deadlocked, errors.first.cause
  end

  test "transactions leaving the lock to the dispatcher enqueue jobs for two keys in opposite order" do
    assert_empty enqueue_in_opposite_orders(acquire: :outside_transaction)
  end

  private
    # Enqueues a job with `acquire` inside a transaction on Solid Queue's
    # connection, and keeps that transaction open while the block runs on
    # another connection. Answers whether the block completed before the
    # transaction ended.
    def completes_while_transaction_is_open?(acquire:, &block)
      enqueued = Concurrent::Event.new
      done = Concurrent::Event.new

      holder = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          SolidQueue::Record.transaction do
            NonOverlappingJob.set(acquire: acquire).perform_later("shared")
            enqueued.set

            done.wait(1.second)
            done.set?
          end
        end
      end

      assert enqueued.wait(5.seconds), "The job inside the transaction was never enqueued"
      block.call
      done.set

      holder.value
    end

    # A job holding the semaphore for the shared key, as one being performed does.
    def enqueue_running_job
      NonOverlappingJob.perform_later("shared")
      SolidQueue::Job.last.tap { |job| assert job.ready? }
    end

    # Two transactions, each enqueueing a job for one key and then, once the
    # other has done the same, a job for the other's key. Answers with the
    # errors raised in either of them.
    def enqueue_in_opposite_orders(acquire:)
      took_first = [ Concurrent::Event.new, Concurrent::Event.new ]

      threads = [ %w[ one two ], %w[ two one ] ].each_with_index.map do |(first, second), index|
        Thread.new do
          SolidQueue::Record.connection_pool.with_connection do
            SolidQueue::Record.transaction do
              NonOverlappingJob.set(acquire: acquire).perform_later(first)
              took_first[index].set
              took_first[1 - index].wait(5.seconds)

              NonOverlappingJob.set(acquire: acquire).perform_later(second)
            end
          end

          nil
        rescue => error
          error
        end
      end

      threads.map(&:value).compact
    end
end
