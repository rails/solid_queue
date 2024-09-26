# frozen_string_literal: true

module SolidQueue
  class JobBatch < Record
    belongs_to :job, foreign_key: :job_id, optional: true
    belongs_to :parent_job_batch, foreign_key: :parent_job_batch_id, class_name: "SolidQueue::JobBatch", optional: true
    has_many :jobs, foreign_key: :batch_id
    has_many :children, foreign_key: :parent_job_batch_id, class_name: "SolidQueue::JobBatch"

    serialize :on_finish_active_job, coder: JSON
    serialize :on_success_active_job, coder: JSON
    serialize :on_failure_active_job, coder: JSON

    scope :incomplete, -> {
      where(finished_at: nil).where("changed_at IS NOT NULL OR last_changed_at < ?", 1.hour.ago)
    }
    scope :finished, -> { where.not(finished_at: nil) }

    class << self
      def current_batch_id
        ActiveSupport::IsolatedExecutionState[:current_batch_id]
      end

      def enqueue(attributes = {})
        job_batch = nil
        transaction do
          job_batch = create!(batch_attributes(attributes))
          wrap_in_batch_context(job_batch.id) do
            yield job_batch
          end
        end

        job_batch
      end

      def dispatch_finished_batches
        incomplete.order(:id).pluck(:id).each do |id|
          transaction do
            where(id: id).includes(:children, :jobs).non_blocking_lock.each(&:finish)
          end
        end
      end

      def wrap_in_batch_context(batch_id)
        previous_batch_id = current_batch_id.presence || nil
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = batch_id
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:current_batch_id] = previous_batch_id
      end

      private

        def batch_attributes(attributes)
          on_finish_klass = attributes.delete(:on_finish)
          on_success_klass = attributes.delete(:on_success)
          on_failure_klass = attributes.delete(:on_failure)

          if on_finish_klass.present?
            attributes[:on_finish_active_job] = as_active_job(on_finish_klass).serialize
          end

          if on_success_klass.present?
            attributes[:on_success_active_job] = as_active_job(on_success_klass).serialize
          end

          if on_failure_klass.present?
            attributes[:on_failure_active_job] = as_active_job(on_failure_klass).serialize
          end

          attributes[:parent_job_batch_id] = current_batch_id if current_batch_id.present?
          # Set it initially, so we check the batch even if there are no jobs
          attributes[:changed_at] = Time.zone.now
          attributes[:last_changed_at] = Time.zone.now

          attributes
        end

        def as_active_job(active_job_klass)
          active_job_klass.is_a?(ActiveJob::Base) ? active_job_klass : active_job_klass.new
        end
    end

    # Instance-level enqueue
    def enqueue(attributes = {})
      raise "You cannot enqueue a batch that is already finished" if finished?

      transaction do
        self.class.wrap_in_batch_context(id) do
          yield self
        end
      end

      self
    end

    def finished?
      finished_at.present?
    end

    def finish
      return if finished?
      reset_changed_at

      all_jobs_succeeded = true
      attrs = {}
      jobs.find_each do |next_job|
        # SolidQueue does treats `discard_on` differently than failures. The job will report as being :finished,
        #   and there is no record of the failure.
        # GoodJob would report a discard as an error. It's possible we should do that in the future?
        if fire_failure_job?(next_job)
          perform_completion_job(:on_failure_active_job, attrs)
          update!(attrs)
        end

        status = next_job.status
        all_jobs_succeeded = all_jobs_succeeded && status != :failed
        return unless status.in?([ :finished, :failed ])
      end

      children.find_each do |child|
        return unless child.finished?
      end

      if on_finish_active_job.present?
        perform_completion_job(:on_finish_active_job, attrs)
      end

      if on_success_active_job.present? && all_jobs_succeeded
        perform_completion_job(:on_success_active_job, attrs)
      end

      transaction do
        parent_job_batch.touch(:changed_at, :last_changed_at) if parent_job_batch_id.present?
        update!({ finished_at: Time.zone.now }.merge(attrs))
      end
    end

    private

      def fire_failure_job?(job)
        return false if on_failure_active_job.blank? || job.failed_execution.blank?
        job = ActiveJob::Base.deserialize(on_failure_active_job)
        job.provider_job_id.blank?
      end

      def perform_completion_job(job_field, attrs)
        active_job = ActiveJob::Base.deserialize(send(job_field))
        active_job.send(:deserialize_arguments_if_needed)
        active_job.arguments = [ self ] + Array.wrap(active_job.arguments)
        self.class.wrap_in_batch_context(id) do
          ActiveJob.perform_all_later([ active_job ])
        end
        active_job.provider_job_id = Job.find_by(active_job_id: active_job.job_id).id
        attrs[job_field] = active_job.serialize
      end

      def reset_changed_at
        if changed_at.blank? && last_changed_at.present?
          update_columns(last_changed_at: Time.zone.now) # wait another hour before we check again
        else
          update_columns(changed_at: nil) # clear out changed_at so we ignore this until the next job finishes
        end
      end
  end
end
