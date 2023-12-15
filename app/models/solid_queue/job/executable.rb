# frozen_string_literal: true

module SolidQueue
  class Job
    module Executable
      extend ActiveSupport::Concern

      included do
        include Clearable, ConcurrencyControls

        has_one :ready_execution, dependent: :destroy
        has_one :claimed_execution, dependent: :destroy
        has_one :failed_execution, dependent: :destroy

        has_one :scheduled_execution, dependent: :destroy

        after_create :prepare_for_execution

        scope :finished, -> { where.not(finished_at: nil) }
      end

      %w[ ready claimed failed scheduled ].each do |status|
        define_method("#{status}?") { public_send("#{status}_execution").present? }
      end

      def prepare_for_execution
        if due? then dispatch
        else
          schedule
        end
      end

      def dispatch
        if acquire_concurrency_lock then ready
        else
          block
        end
      end

      def finished!
        if preserve_finished_jobs?
          touch(:finished_at)
        else
          destroy!
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

      def failed_with(exception)
        FailedExecution.create_or_find_by!(job_id: id, exception: exception)
      end

      private
        def due?
          scheduled_at.nil? || scheduled_at <= Time.current
        end

        def schedule
          ScheduledExecution.create_or_find_by!(job_id: id)
        end

        def ready
          ReadyExecution.create_or_find_by!(job_id: id)
        end


        def preserve_finished_jobs?
          SolidQueue.preserve_finished_jobs
        end
    end
  end
end
