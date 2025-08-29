# frozen_string_literal: true

require_relative "batch/empty_job"
require_relative "batch/cleanup_job"

module SolidQueue
  class Batch
    include GlobalID::Identification

    delegate :completed_jobs, :failed_jobs, :pending_jobs, :total_jobs, :progress_percentage,
      :finished?, :processing?, :pending?, :status, :batch_id,
      :metadata, :metadata=,
      :on_success, :on_success=,
      :on_failure, :on_failure=,
      :on_finish, :on_finish=,
      :reload,
      to: :batch_record

    def initialize(_batch_record: nil)
      @batch_record = _batch_record || BatchRecord.new
    end

    def batch_record
      @batch_record
    end

    def id
      batch_id
    end

    def enqueue(&block)
      raise "You cannot enqueue a batch that is already finished" if finished?

      SolidQueue::BatchRecord::Buffer.capture_child_batch(self) if batch_record.new_record?

      buffer = SolidQueue::BatchRecord::Buffer.new
      buffer.capture do
        Batch.wrap_in_batch_context(batch_id) do
          block.call(self)
        end
      end

      if enqueue_after_transaction_commit?
        ActiveRecord.after_all_transactions_commit do
          enqueue_batch(buffer)
        end
      else
        enqueue_batch(buffer)
      end
    end

    private

      def enqueue_after_transaction_commit?
        return false unless defined?(ApplicationJob.enqueue_after_transaction_commit)

        case ApplicationJob.enqueue_after_transaction_commit
        when :always, true
          true
        when :never, false
          false
        when :default
          true
        end
      end

      def enqueue_batch(buffer)
        if batch_record.new_record?
          enqueue_new_batch(buffer)
        else
          jobs = buffer.jobs.values
          enqueue_existing_batch(jobs)
        end
      end

      def enqueue_new_batch(buffer)
        SolidQueue::BatchRecord.transaction do
          batch_record.save!

          # If batch has no jobs, enqueue an EmptyJob
          # This ensures callbacks always execute, even for empty batches
          jobs = buffer.jobs.values
          if jobs.empty?
            empty_job = SolidQueue::Batch::EmptyJob.new
            empty_job.batch_id = batch_record.batch_id
            jobs = [ empty_job ]
          end

          batch_record.update!(
            total_jobs: jobs.size,
            pending_jobs: SolidQueue::Job.enqueue_all(jobs),
            expected_children: buffer.child_batches.size
          )
        end
      end

      def enqueue_existing_batch(active_jobs)
        jobs = Array.wrap(active_jobs)
        enqueued_count = SolidQueue::Job.enqueue_all(jobs)

        Batch.update_job_count(batch_id, enqueued_count)
      end

    class << self
      def enqueue(on_success: nil, on_failure: nil, on_finish: nil, metadata: nil, &block)
        new.tap do |batch|
          batch.batch_record.assign_attributes(
            on_success: on_success,
            on_failure: on_failure,
            on_finish: on_finish,
            metadata: metadata,
            parent_job_batch_id: current_batch_id
          )

          batch.enqueue(&block)
        end
      end

      def find(batch_id)
        new(_batch_record: BatchRecord.find_by!(batch_id: batch_id))
      end

      def update_job_count(batch_id, count)
        BatchRecord.where(batch_id: batch_id).update_all(
          "total_jobs = total_jobs + #{count}, pending_jobs = pending_jobs + #{count}"
        )
      end

      def current_batch_id
        ActiveSupport::IsolatedExecutionState[:current_batch_id]
      end

      def wrap_in_batch_context(batch_id)
        previous_batch_id = current_batch_id.presence || nil
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = batch_id
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = previous_batch_id
      end
    end
  end
end
