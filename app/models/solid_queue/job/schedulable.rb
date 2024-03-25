# frozen_string_literal: true

module SolidQueue
  class Job
    module Schedulable
      extend ActiveSupport::Concern

      included do
        has_one :scheduled_execution

        scope :scheduled, -> { where(finished_at: nil) }
      end

      class_methods do
        def schedule_all(jobs)
          schedule_all_at_once(jobs)
          successfully_scheduled(jobs)
        end

        private
          def schedule_all_at_once(jobs)
            ScheduledExecution.create_all_from_jobs(jobs)
          end

          def successfully_scheduled(jobs)
            where(id: ScheduledExecution.where(job_id: jobs.map(&:id)).pluck(:job_id))
          end
      end

      def due?
        scheduled_at.nil? || scheduled_at <= Time.current
      end

      def scheduled?
        scheduled_execution.present?
      end

      private
        def schedule
          ScheduledExecution.create_or_find_by!(job_id: id)
        end

        def execution
          super || scheduled_execution
        end
    end
  end
end
