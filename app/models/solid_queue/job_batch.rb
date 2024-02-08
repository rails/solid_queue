# frozen_string_literal: true

module SolidQueue
  class JobBatch < Record
    belongs_to :job, foreign_key: :job_id, optional: true
    has_many :jobs, foreign_key: :batch_id

    serialize :on_finish_active_job, coder: JSON
    serialize :on_success_active_job, coder: JSON

    scope :incomplete, -> {
      where(finished_at: nil).where("changed_at IS NOT NULL OR last_changed_at < ?", 1.hour.ago)
    }

    class << self
      def current_batch_id
        ActiveSupport::IsolatedExecutionState[:current_batch_id]
      end

      def enqueue(attributes = {})
        previous_batch_id = current_batch_id.presence || nil

        job_batch = nil
        transaction do
          job_batch = create!(batch_attributes(attributes))
          ActiveSupport::IsolatedExecutionState[:current_batch_id] = job_batch.id
          yield job_batch
        end

        job_batch
      ensure
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = previous_batch_id
      end

      def dispatch_finished_batches
        incomplete.order(:id).pluck(:id).each do |id|
          transaction do
            where(id:).non_blocking_lock.each(&:finish)
          end
        end
      end

      private

        def batch_attributes(attributes)
          on_finish_klass = attributes.delete(:on_finish)
          on_success_klass = attributes.delete(:on_success)

          if on_finish_klass.present?
            attributes[:on_finish_active_job] = as_active_job(on_finish_klass).serialize
          end

          if on_success_klass.present?
            attributes[:on_success_active_job] = as_active_job(on_success_klass).serialize
          end

          attributes
        end

        def as_active_job(active_job_klass)
          active_job_klass.is_a?(ActiveJob::Base) ? active_job_klass : active_job_klass.new
        end
    end

    def finished?
      finished_at.present?
    end

    def finish
      return if finished?
      reset_changed_at
      jobs.find_each do |next_job|
        # FIXME: If it's failed but is going to retry, how do we know?
        #   Because we need to know if we will determine what the failed execution means
        # FIXME: use "success" vs "finish" vs "discard" `completion_type` to determine
        #   how to analyze each job
        return unless next_job.finished?
      end

      attrs = {}

      if on_finish_active_job.present?
        active_job = ActiveJob::Base.deserialize(on_finish_active_job)
        active_job.send(:deserialize_arguments_if_needed)
        ActiveJob.perform_all_later([active_job])
        attrs[:job] = Job.find_by(active_job_id: active_job.job_id)
      end

      update!({ finished_at: Time.zone.now }.merge(attrs))
    end

    private

      def reset_changed_at
        if changed_at.blank? && last_changed_at.present?
          update_columns(last_changed_at: Time.zone.now) # wait another hour before we check again
        else
          update_columns(changed_at: nil) # clear out changed_at so we ignore this until the next job finishes
        end
      end
  end
end
