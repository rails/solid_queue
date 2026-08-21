# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    class AlreadyFinished < StandardError; end

    class PendingMigrations < StandardError
      def initialize(message = "The batches schema hasn't been installed yet. Run `bin/rails solid_queue:update` to copy the pending migrations to your application, and then `bin/rails db:migrate` to run them")
        super
      end
    end

    include Callbacks, Status
    include Clearable, Sweepable

    has_many :jobs
    has_many :batch_executions, dependent: :destroy

    store :metadata, coder: JSON

    # Join-free so update_all keeps this condition in the completion update's own WHERE
    scope :without_executions, -> { where.not(id: BatchExecution.select(:batch_id)) }

    # Provider-agnostic batch identifier, analogous to jobs.active_job_id.
    before_create :set_active_job_batch_id
    after_commit :start, on: :create, unless: -> { ActiveRecord.respond_to?(:after_all_transactions_commit) }

    class << self
      # The batches schema ships as an optional migration in Solid Queue 1.x
      # and becomes part of the base schema in 2.0. Until the app has run the
      # migration, jobs enqueue without any batch bookkeeping and batches
      # themselves can't be used.
      def migrated?
        @migrated ||= table_exists? && BatchExecution.table_exists? && Job.column_names.include?("batch_id")
      end

      def enqueue(description: nil, on_success: nil, on_failure: nil, on_finish: nil, metadata: nil, **extra_metadata, &block)
        raise PendingMigrations unless migrated?

        new.tap do |batch|
          batch.assign_attributes(description:, on_success:, on_failure:, on_finish:, metadata: (metadata || {}).merge(extra_metadata))
          batch.enqueue(&block)
        end
      end

      def current_batch_id
        ActiveSupport::IsolatedExecutionState[:current_batch_id]
      end

      def wrap_in_batch_context(batch_id)
        previous_batch_id = current_batch_id.presence
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = batch_id
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = previous_batch_id
      end
    end

    def enqueue(&block)
      # Fast-fail for the common case. create_all_from_jobs atomically guards
      # concurrent additions when it creates their tracking rows.
      if finished?
        raise AlreadyFinished, "Can't enqueue an already finished batch"
      end

      transaction do
        save! if new_record?

        self.class.wrap_in_batch_context(id) { block&.call(self) }

        if ActiveRecord.respond_to?(:after_all_transactions_commit)
          ActiveRecord.after_all_transactions_commit { start }
        end
      end
    end

    def metadata
      (super || {}).with_indifferent_access
    end

    def start
      mark_as_enqueued

      # Refresh enqueued_at after marking as enqueued, and let a batch that started
      # with no jobs finish right away
      reload
      finish
    end

    def finish
      return if finished? || !enqueued?
      return if batch_executions.exists?

      transaction do
        updated = Batch.where(id: id).unfinished.enqueued.without_executions.update_all(finished_at: Time.current)
        finalize if updated > 0
      end
    end

    private
      def set_active_job_batch_id
        self.active_job_batch_id ||= SecureRandom.uuid
      end

      def mark_as_enqueued
        Batch.where(id: id, enqueued_at: nil).update_all(enqueued_at: Time.current)
      end

      def finalize
        reload

        # PostgreSQL can let a blocked CAS win from a stale NOT EXISTS snapshot:
        # after a lock wait, READ COMMITTED re-checks the target row's conditions
        # against the latest data but keeps the original snapshot for subqueries.
        # Re-check in a new statement, which gets a fresh snapshot while this
        # transaction's row lock keeps adders out, since they increment before
        # inserting their executions. MySQL doesn't need this: it reads DML
        # subqueries from the latest committed data, so its CAS can't win wrongly.
        raise ActiveRecord::Rollback if batch_executions.exists?

        SolidQueue.instrument(:finish_batch, batch_id: id) do |payload|
          failed_jobs = jobs.failed.count
          failed_at = Time.current if failed_jobs > 0
          completed_jobs = total_jobs - failed_jobs

          update_columns(failed_jobs:, failed_at:, completed_jobs:)
          enqueue_callback_jobs

          payload.merge!(total_jobs:, failed_jobs:, completed_jobs:)
        end
      end
  end
end
