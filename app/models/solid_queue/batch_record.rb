# frozen_string_literal: true

module SolidQueue
  class BatchRecord < Record
    self.table_name = "solid_queue_job_batches"

    STATUSES = %w[pending processing completed failed]

    belongs_to :parent_job_batch, foreign_key: :parent_job_batch_id, class_name: "SolidQueue::BatchRecord", optional: true
    has_many :jobs, foreign_key: :batch_id, primary_key: :batch_id
    has_many :children, foreign_key: :parent_job_batch_id, primary_key: :batch_id, class_name: "SolidQueue::BatchRecord"

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
    before_create :set_parent_job_batch_id

    def on_success=(value)
      super(serialize_callback(value))
    end

    def on_failure=(value)
      super(serialize_callback(value))
    end

    def on_finish=(value)
      super(serialize_callback(value))
    end

    def job_finished!(job)
      return if finished?
      return if job.batch_processed_at?

      job.with_lock do
        if job.batch_processed_at.blank?
          job.update!(batch_processed_at: Time.current)

          if job.failed_execution.present?
            self.class.where(id: id).update_all(
              "failed_jobs = failed_jobs + 1, pending_jobs = pending_jobs - 1"
            )
          else
            self.class.where(id: id).update_all(
              "completed_jobs = completed_jobs + 1, pending_jobs = pending_jobs - 1"
            )
          end
        end
      end

      reload
      check_completion!
    end

    def check_completion!
      return if finished?

      actual_children = children.count
      return if actual_children < expected_children

      children.find_each do |child|
        return unless child.finished?
      end

      with_lock do
        if finished?
          # do nothing
        elsif pending_jobs <= 0
          if failed_jobs > 0
            mark_as_failed!
          else
            mark_as_completed!
          end
          clear_unpreserved_jobs
        elsif status == "pending"
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

      def set_parent_job_batch_id
        self.parent_job_batch_id ||= Batch.current_batch_id if Batch.current_batch_id.present?
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
        active_job.arguments = [ Batch.new(_batch_record: self) ] + Array.wrap(active_job.arguments)
        SolidQueue::Job.enqueue_all([ active_job ])

        active_job.provider_job_id = Job.find_by(active_job_id: active_job.job_id).id
        attrs[job_field] = active_job.serialize
      end

      def mark_as_completed!
        # SolidQueue does treats `discard_on` differently than failures. The job will report as being :finished,
        #   and there is no record of the failure.
        # GoodJob would report a discard as an error. It's possible we should do that in the future?
        update!(status: "completed", finished_at: Time.current)

        perform_completion_job(:on_success, {}) if on_success.present?
        perform_completion_job(:on_finish, {}) if on_finish.present?

        if parent_job_batch_id.present?
          parent = BatchRecord.find_by(batch_id: parent_job_batch_id)
          parent&.reload&.check_completion!
        end
      end

      def mark_as_failed!
        update!(status: "failed", finished_at: Time.current)
        perform_completion_job(:on_failure, {}) if on_failure.present?
        perform_completion_job(:on_finish, {}) if on_finish.present?

        # Check if parent batch can now complete
        if parent_job_batch_id.present?
          parent = BatchRecord.find_by(batch_id: parent_job_batch_id)
          parent&.check_completion!
        end
      end

      def clear_unpreserved_jobs
        SolidQueue::Batch::CleanupJob.perform_later(self) unless SolidQueue.preserve_finished_jobs?
      end
  end
end

require_relative "batch_record/buffer"
