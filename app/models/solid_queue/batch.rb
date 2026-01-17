# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    class AlreadyFinished < StandardError; end

    include Trackable

    has_many :jobs
    has_many :batch_executions, class_name: "SolidQueue::BatchExecution", dependent: :destroy

    serialize :metadata, coder: JSON
    %w[ finish success failure ].each do |callback_type|
      serialize "on_#{callback_type}", coder: JSON

      define_method("on_#{callback_type}=") do |callback|
        super serialize_callback(callback)
      end
    end

    after_initialize :set_active_job_batch_id
    after_commit :start_batch, on: :create, unless: -> { ActiveRecord.respond_to?(:after_all_transactions_commit) }

    def enqueue(&block)
      raise AlreadyFinished, "You cannot enqueue a batch that is already finished" if finished?

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
      return if batch_executions.any?
      rows = Batch
        .where(id: id)
        .unfinished
        .empty_executions
        .update_all(finished_at: Time.current)

      return if rows.zero?

      with_lock do
        failed = jobs.joins(:failed_execution).count
        finished_attributes = {}
        if failed > 0
          finished_attributes[:failed_at] = Time.current
          finished_attributes[:failed_jobs] = failed
        end
        finished_attributes[:completed_jobs] = total_jobs - failed

        update!(finished_attributes)
        enqueue_callback_jobs
      end
    end

    private

      def set_active_job_batch_id
        self.active_job_batch_id ||= SecureRandom.uuid
      end

      def as_active_job(active_job_klass)
        active_job_klass.is_a?(ActiveJob::Base) ? active_job_klass : active_job_klass.new
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
        active_job.send(:deserialize_arguments_if_needed)
        active_job.arguments = [ self ] + Array.wrap(active_job.arguments)
        active_job.enqueue
      end

      def enqueue_callback_jobs
        if failed_at?
          enqueue_callback_job(:on_failure) if on_failure.present?
        else
          enqueue_callback_job(:on_success) if on_success.present?
        end

        enqueue_callback_job(:on_finish) if on_finish.present?
      end

      def enqueue_empty_job
        Batch.wrap_in_batch_context(id) do
          EmptyJob.perform_later
        end
      end

      def start_batch
        enqueue_empty_job if reload.total_jobs == 0
        update!(enqueued_at: Time.current)
      end

    class << self
      def enqueue(on_success: nil, on_failure: nil, on_finish: nil, **metadata, &block)
        new.tap do |batch|
          batch.assign_attributes(
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
  end
end
