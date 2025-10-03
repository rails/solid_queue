# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    include Trackable

    has_many :jobs, foreign_key: :batch_id, primary_key: :batch_id
    has_many :batch_executions, foreign_key: :batch_id, primary_key: :batch_id, class_name: "SolidQueue::BatchExecution",
      dependent: :destroy

    serialize :on_finish, coder: JSON
    serialize :on_success, coder: JSON
    serialize :on_failure, coder: JSON
    serialize :metadata, coder: JSON

    after_initialize :set_batch_id
    after_commit :start_batch, on: :create, unless: -> { ActiveRecord.respond_to?(:after_all_transactions_commit) }

    mattr_accessor :maintenance_queue_name
    self.maintenance_queue_name = "default"

    def enqueue(&block)
      raise "You cannot enqueue a batch that is already finished" if finished?

      transaction do
        save! if new_record?

        Batch.wrap_in_batch_context(batch_id) do
          block&.call(self)
        end

        if ActiveRecord.respond_to?(:after_all_transactions_commit)
          ActiveRecord.after_all_transactions_commit do
            start_batch
          end
        end
      end
    end

    def on_success=(value)
      super(serialize_callback(value))
    end

    def on_failure=(value)
      super(serialize_callback(value))
    end

    def on_finish=(value)
      super(serialize_callback(value))
    end

    def check_completion!
      return if finished? || !ready?
      return if batch_executions.limit(1).exists?

      rows = Batch
        .by_batch_id(batch_id)
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
        execute_callbacks
      end
    end

    private

      def set_batch_id
        self.batch_id ||= SecureRandom.uuid
      end

      def as_active_job(active_job_klass)
        active_job_klass.is_a?(ActiveJob::Base) ? active_job_klass : active_job_klass.new
      end

      def serialize_callback(value)
        return value if value.blank?
        active_job = as_active_job(value)
        # We can pick up batch ids from context, but callbacks should never be considered a part of the batch
        active_job.batch_id = nil
        active_job.serialize
      end

      def perform_completion_job(job_field, attrs)
        active_job = ActiveJob::Base.deserialize(send(job_field))
        active_job.send(:deserialize_arguments_if_needed)
        active_job.arguments = [ self ] + Array.wrap(active_job.arguments)
        SolidQueue::Job.enqueue_all([ active_job ])

        active_job.provider_job_id = Job.find_by(active_job_id: active_job.job_id).id
        attrs[job_field] = active_job.serialize
      end

      def execute_callbacks
        if failed_at?
          perform_completion_job(:on_failure, {}) if on_failure.present?
        else
          perform_completion_job(:on_success, {}) if on_success.present?
        end

        perform_completion_job(:on_finish, {}) if on_finish.present?
      end

      def enqueue_empty_job
        Batch.wrap_in_batch_context(batch_id) do
          EmptyJob.set(queue: self.class.maintenance_queue_name || "default").perform_later
        end
      end

      def start_batch
        enqueue_empty_job if reload.total_jobs == 0
        update!(enqueued_at: Time.current)
      end

    class << self
      def enqueue(on_success: nil, on_failure: nil, on_finish: nil, metadata: nil, &block)
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
        previous_batch_id = current_batch_id.presence || nil
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = batch_id
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = previous_batch_id
      end
    end
  end
end
