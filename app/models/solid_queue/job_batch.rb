# frozen_string_literal: true

module SolidQueue
  class JobBatch < Record
    belongs_to :job, foreign_key: :job_id, optional: true
    has_many :jobs, foreign_key: :batch_id

    scope :incomplete, -> {
      where(finished_at: nil).where("changed_at IS NOT NULL OR last_changed_at < ?", 1.hour.ago)
    }

    class << self
      def current_batch_id
        Thread.current[:current_batch_id]
      end

      def enqueue(attributes = {})
        previous_batch_id = current_batch_id.presence || nil

        job_batch = nil
        transaction do
          job_batch = create!(batch_attributes(attributes))
          Thread.current[:current_batch_id] = job_batch.id
          yield
        end

        job_batch
      ensure
        Thread.current[:current_batch_id] = previous_batch_id
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
          attributes = case attributes
          in { on_finish: on_finish_klass }
            attributes.merge(
              job_class: on_finish_klass,
              completion_type: "success"
            )
          in { on_success: on_success_klass }
            attributes.merge(
              job_class: on_success_klass,
              completion_type: "success"
            )
          end

          attributes.except(:on_finish, :on_success)
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

      if job_class.present?
        job_klass = job_class.constantize
        active_job = job_klass.perform_later(self)
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
