module SolidQueue
  module Job::Executable
    extend ActiveSupport::Concern

    included do
      has_one :ready_execution, dependent: :destroy
      has_one :claimed_execution, dependent: :destroy
      has_one :failed_execution, dependent: :destroy

      has_one :scheduled_execution, dependent: :destroy

      after_create :prepare_for_execution

      scope :finished, -> { where.not(finished_at: nil) }
    end

    STATUSES = %w[ ready claimed failed scheduled ]

    STATUSES.each do |status|
      define_method("#{status}?") { public_send("#{status}_execution").present? }
    end

    def prepare_for_execution
      if due?
        ReadyExecution.create_or_find_by!(job_id: id)
      else
        ScheduledExecution.create_or_find_by!(job_id: id)
      end
    end

    def finished!
      if delete_finished_jobs?
        destroy!
      else
        touch(:finished_at)
      end
    end

    def finished?
      finished_at.present?
    end

    def failed_with(exception)
      FailedExecution.create_or_find_by!(job_id: id, exception: exception)
    end

    def discard
      destroy unless claimed?
    end

    def retry
      failed_execution&.retry
    end

    private
      def due?
        scheduled_at.nil? || scheduled_at <= Time.current
      end

      def delete_finished_jobs?
        SolidQueue.delete_finished_jobs
      end
  end
end
