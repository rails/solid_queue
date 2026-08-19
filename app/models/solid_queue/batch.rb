# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    class AlreadyFinished < StandardError; end

    class PendingMigrations < StandardError
      def initialize(message = "The batches schema hasn't been installed yet. Run `bin/rails solid_queue:update` to copy the pending migrations to your application, and then `bin/rails db:migrate` to run them")
        super
      end
    end

    include Trackable, Clearable, Sweepable

    has_many :jobs
    has_many :batch_executions, class_name: "SolidQueue::BatchExecution", dependent: :destroy

    serialize :metadata, coder: JSON

    %w[ finish success failure ].each do |callback_type|
      serialize "on_#{callback_type}", coder: JSON

      define_method("on_#{callback_type}=") do |callback|
        super serialize_callback(callback)
      end
    end

    # Provider-agnostic batch identifier, analogous to jobs.active_job_id.
    before_create :set_active_job_batch_id

    after_commit :start_batch, on: :create, unless: -> { ActiveRecord.respond_to?(:after_all_transactions_commit) }

    class << self
      # The batches schema ships as an optional migration in Solid Queue 1.x
      # and becomes part of the base schema in 2.0. Until the app has run the
      # migration, jobs enqueue without any batch bookkeeping and batches
      # themselves can't be used.
      def migrated?
        @migrated ||= table_exists? && BatchExecution.table_exists? && Job.column_names.include?("batch_id")
      end

      def enqueue(description: nil, on_success: nil, on_failure: nil, on_finish: nil, **metadata, &block)
        raise PendingMigrations unless migrated?

        new.tap do |batch|
          batch.assign_attributes(
            description: description,
            on_success: on_success,
            on_failure: on_failure,
            on_finish: on_finish,
            metadata: metadata
          )

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

        Batch.wrap_in_batch_context(id) do
          block&.call(self)
        end

        if ActiveRecord.respond_to?(:after_all_transactions_commit)
          ActiveRecord.after_all_transactions_commit do
            start_batch
          end
        end
      end
    end

    def metadata
      (super || {}).with_indifferent_access
    end

    def check_completion
      return if finished? || !enqueued?
      return if batch_executions.exists?

      transaction do
        finished_rows = Batch.where(id: id).unfinished.enqueued.empty_executions.update_all(finished_at: Time.current)
        finalize_completion if finished_rows.positive?
      end
    end

    def start_batch
      Batch.where(id: id, enqueued_at: nil).update_all(enqueued_at: Time.current)

      # Refresh enqueued_at after the update_all, and let a batch that started
      # with no jobs finish right away
      reload
      check_completion
    end

    private
      def set_active_job_batch_id
        self.active_job_batch_id ||= SecureRandom.uuid
      end

      def finalize_completion
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
          failed = jobs.failed.count
          finished_attributes = { completed_jobs: total_jobs - failed }
          if failed > 0
            finished_attributes[:failed_at] = Time.current
            finished_attributes[:failed_jobs] = failed
          end

          update_columns(finished_attributes)
          enqueue_callback_jobs

          payload[:total_jobs] = total_jobs
          payload[:completed_jobs] = self[:completed_jobs]
          payload[:failed_jobs] = failed
        end
      end

      def serialize_callback(value)
        if value.present?
          active_job = value.is_a?(ActiveJob::Base) ? value : value.new
          # We can pick up batch ids from context, but callbacks should never be considered a part of the batch
          active_job.batch_id = nil
          active_job.serialize
        end
      end

      def enqueue_callback_job(callback_name)
        active_job = ActiveJob::Base.deserialize(send(callback_name))
        active_job.callback_batch_id = id
        # Bypass the job class's adapter so callbacks stay in Solid Queue and
        # their enqueue stays in this transaction, while honoring enqueue callbacks.
        active_job.run_callbacks(:enqueue) do
          Job.enqueue(active_job, scheduled_at: active_job.scheduled_at || Time.current)
        end
      end

      def enqueue_callback_jobs
        if failed_at?
          enqueue_callback_job(:on_failure) if on_failure.present?
        else
          enqueue_callback_job(:on_success) if on_success.present?
        end

        enqueue_callback_job(:on_finish) if on_finish.present?
      end
  end
end
