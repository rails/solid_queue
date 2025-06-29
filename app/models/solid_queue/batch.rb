# frozen_string_literal: true

module SolidQueue
  class Batch < Record
    serialize :on_complete_job_args, coder: JSON
    serialize :on_success_job_args, coder: JSON
    serialize :on_failure_job_args, coder: JSON
    serialize :metadata, coder: JSON

    STATUSES = %w[pending processing completed failed]

    validates :batch_id, uniqueness: true
    validates :status, inclusion: { in: STATUSES }

    has_many :jobs, foreign_key: :batch_id, primary_key: :batch_id, dependent: :nullify

    scope :pending, -> { where(status: "pending") }
    scope :processing, -> { where(status: "processing") }
    scope :completed, -> { where(status: "completed") }
    scope :failed, -> { where(status: "failed") }
    scope :finished, -> { where(status: %w[completed failed]) }
    scope :unfinished, -> { where(status: %w[pending processing]) }

    before_create :set_batch_id

    class << self
      def enqueue(job_instances, on_complete: nil, on_success: nil, on_failure: nil, metadata: {})
        return 0 if job_instances.empty?

        batch = create!(
          on_complete_job_class: on_complete&.dig(:job)&.to_s,
          on_complete_job_args: on_complete&.dig(:args),
          on_success_job_class: on_success&.dig(:job)&.to_s,
          on_success_job_args: on_success&.dig(:args),
          on_failure_job_class: on_failure&.dig(:job)&.to_s,
          on_failure_job_args: on_failure&.dig(:args),
          metadata: metadata,
          total_jobs: job_instances.size,
          pending_jobs: job_instances.size
        )

        # Add batch_id to each job
        job_instances.each do |job|
          job.batch_id = batch.batch_id
        end

        # Use SolidQueue's bulk enqueue
        enqueued_count = SolidQueue::Job.enqueue_all(job_instances)

        # Update pending count if some jobs failed to enqueue
        if enqueued_count < job_instances.size
          batch.update!(pending_jobs: enqueued_count)
        end

        batch
      end
    end

    def add_jobs(job_instances)
      return 0 if job_instances.empty? || finished?

      job_instances.each do |job|
        job.batch_id = batch_id
      end

      enqueued_count = SolidQueue::Job.enqueue_all(job_instances)

      increment!(:total_jobs, job_instances.size)
      increment!(:pending_jobs, enqueued_count)

      enqueued_count
    end

    def job_finished!(job)
      return if finished?

      transaction do
        if job.failed_execution.present?
          increment!(:failed_jobs)
        else
          increment!(:completed_jobs)
        end

        decrement!(:pending_jobs)

        check_completion!
      end
    end

    def check_completion!
      return if finished?

      if pending_jobs <= 0
        if failed_jobs > 0
          mark_as_failed!
        else
          mark_as_completed!
        end
      elsif status == "pending"
        update!(status: "processing")
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
      def set_batch_id
        self.batch_id ||= SecureRandom.uuid
      end

      def mark_as_completed!
        update!(status: "completed", completed_at: Time.current)
        enqueue_callback(:on_success)
        enqueue_callback(:on_complete)
      end

      def mark_as_failed!
        update!(status: "failed", completed_at: Time.current)
        enqueue_callback(:on_failure)
        enqueue_callback(:on_complete)
      end

      def enqueue_callback(callback_type)
        job_class = public_send("#{callback_type}_job_class")
        job_args = public_send("#{callback_type}_job_args")

        return unless job_class.present?

        job_class.constantize.perform_later(
          batch_id: batch_id,
          **(job_args || {}).symbolize_keys
        )
      rescue => e
        Rails.logger.error "[SolidQueue] Failed to enqueue #{callback_type} callback for batch #{batch_id}: #{e.message}"
      end
  end
end
