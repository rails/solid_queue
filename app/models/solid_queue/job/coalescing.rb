# frozen_string_literal: true

module SolidQueue
  class Job
    module Coalescing
      extend ActiveSupport::Concern

      class_methods do
        def enqueue_coalesced(active_job)
          raise CoalesceKey::PendingMigrations unless CoalesceKey.migrated?

          transaction do
            coalesce_key = CoalesceKey.admit(active_job.coalesce_key)

            if coalesce_key.job_id
              discard_into(coalesce_key.job_id, active_job)
            else
              create_for(coalesce_key, active_job)
            end
          end
        rescue ActiveRecord::ActiveRecordError => e
          enqueue_error = EnqueueError.new("#{e.class.name}: #{e.message}").tap do |error|
            error.set_backtrace e.backtrace
          end
          raise enqueue_error
        end

        private
          def discard_into(job_id, active_job)
            active_job.provider_job_id = job_id
            active_job.successfully_enqueued = false
            active_job.coalesce_status = :discarded
            nil
          end

          def create_for(coalesce_key, active_job)
            create_from_active_job(active_job).tap do |job|
              if job.persisted?
                coalesce_key.update!(job: job)
                active_job.provider_job_id = job.id
                active_job.coalesce_status = :created
              else
                coalesce_key.destroy!
              end

              active_job.successfully_enqueued = job.persisted?
            end
          end
      end
    end
  end
end
