# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    STATUSES = %w[pending processing completed failed]

    belongs_to :parent_batch, foreign_key: :parent_batch_id, class_name: "SolidQueue::Batch", optional: true
    has_many :jobs, foreign_key: :batch_id, primary_key: :batch_id
    has_many :batch_executions, foreign_key: :batch_id, primary_key: :batch_id, class_name: "SolidQueue::BatchExecution"
    has_many :child_batches, foreign_key: :parent_batch_id, primary_key: :batch_id, class_name: "SolidQueue::Batch"

    serialize :on_finish, coder: JSON
    serialize :on_success, coder: JSON
    serialize :on_failure, coder: JSON
    serialize :metadata, coder: JSON

    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: "pending") }
    scope :processing, -> { where(status: "processing") }
    scope :completed, -> { where(status: "completed") }
    scope :failed, -> { where(status: "failed") }
    scope :finished, -> { where(status: %w[completed failed]) }
    scope :unfinished, -> { where(status: %w[pending processing]) }

    after_initialize :set_batch_id
    before_create :set_parent_batch_id

    def enqueue(&block)
      raise "You cannot enqueue a batch that is already finished" if finished?

      SolidQueue::Batch::Buffer.capture_child_batch(self) if new_record?

      buffer = SolidQueue::Batch::Buffer.new
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
      return if finished?

      with_lock do
        return if finished_at?

        if pending_jobs == 0
          unfinished_children = child_batches.where.not(status: %w[completed failed]).count

          if total_child_batches == 0 || unfinished_children == 0
            new_status = failed_jobs > 0 ? "failed" : "completed"
            update!(status: new_status, finished_at: Time.current)
            execute_callbacks
          end
        elsif status == "pending" && (completed_jobs > 0 || failed_jobs > 0)
          # Move from pending to processing once any job completes
          update!(status: "processing")
        end
      end
    end

    def finished?
      status.in?(%w[completed failed])
    end

    def processing?
      status == "processing"
    end

    def pending?
      status == "pending"
    end

    def progress_percentage
      return 0 if total_jobs == 0
      ((completed_jobs + failed_jobs) * 100.0 / total_jobs).round(2)
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
        if new_record?
          enqueue_new_batch(buffer)
        else
          enqueue_existing_batch(buffer)
        end
      end

      def enqueue_new_batch(buffer)
        SolidQueue::Batch.transaction do
          save!

          # If batch has no jobs, enqueue an EmptyJob
          # This ensures callbacks always execute, even for empty batches
          jobs = buffer.jobs.values
          if jobs.empty?
            empty_job = SolidQueue::Batch::EmptyJob.new
            empty_job.batch_id = batch_id
            jobs = [ empty_job ]
          end

          # Enqueue jobs - this handles creation and preparation
          enqueued_count = SolidQueue::Job.enqueue_all(jobs)

          persisted_jobs = jobs.select { |job| job.provider_job_id.present? }
          SolidQueue::BatchExecution.track_job_creation(persisted_jobs, batch_id)

          # Update batch record with counts
          update!(
            total_jobs: enqueued_count,
            pending_jobs: enqueued_count,
            total_child_batches: buffer.child_batches.size
          )
        end
      end

      def enqueue_existing_batch(buffer)
        jobs = buffer.jobs.values
        new_child_batches = buffer.child_batches.size

        SolidQueue::Batch.transaction do
          enqueued_count = SolidQueue::Job.enqueue_all(jobs)

          persisted_jobs = jobs.select(&:successfully_enqueued?)
          SolidQueue::BatchExecution.track_job_creation(persisted_jobs, batch_id)

          Batch.where(batch_id: batch_id).update_all([
            "total_jobs = total_jobs + ?, pending_jobs = pending_jobs + ?, total_child_batches = total_child_batches + ?",
            enqueued_count, enqueued_count, new_child_batches
          ])
        end

        jobs.count(&:successfully_enqueued?)
      end

      def set_parent_batch_id
        self.parent_batch_id ||= Batch.current_batch_id if Batch.current_batch_id.present?
      end

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
        if status == "failed"
          perform_completion_job(:on_failure, {}) if on_failure.present?
        elsif status == "completed"
          perform_completion_job(:on_success, {}) if on_success.present?
        end

        perform_completion_job(:on_finish, {}) if on_finish.present?

        clear_unpreserved_jobs

        check_parent_completion!
      end

      def clear_unpreserved_jobs
        SolidQueue::Batch::CleanupJob.perform_later(self) unless SolidQueue.preserve_finished_jobs?
      end

      def check_parent_completion!
        if parent_batch_id.present?
          parent = Batch.find_by(batch_id: parent_batch_id)
          parent&.check_completion! unless parent&.finished?
        end
      end

    class << self
      def enqueue(on_success: nil, on_failure: nil, on_finish: nil, metadata: nil, &block)
        new.tap do |batch|
          batch.assign_attributes(
            on_success: on_success,
            on_failure: on_failure,
            on_finish: on_finish,
            metadata: metadata,
            parent_batch_id: current_batch_id
          )

          batch.enqueue(&block)
        end
      end

      def update_job_count(batch_id, count)
        count = count.to_i
        Batch.where(batch_id: batch_id).update_all(
          "total_jobs = total_jobs + #{count}, pending_jobs = pending_jobs + #{count}",
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

require_relative "batch/buffer"
