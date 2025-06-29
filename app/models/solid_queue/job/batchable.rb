# frozen_string_literal: true

module SolidQueue
  class Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        belongs_to :batch, foreign_key: :batch_id, primary_key: :batch_id, optional: true, class_name: "SolidQueue::Batch"

        scope :in_batch, ->(batch_id) { where(batch_id: batch_id) }
        scope :without_batch, -> { where(batch_id: nil) }
        scope :batch_pending, -> { in_batch.where(finished_at: nil) }
        scope :batch_finished, -> { in_batch.where.not(finished_at: nil) }

        after_update :notify_batch_if_finished, if: :batch_id?
      end

      class_methods do
        def enqueue_batch(active_jobs, **batch_options)
          return 0 if active_jobs.empty?

          Batch.enqueue(active_jobs, **batch_options)
        end

        def create_all_from_active_jobs_with_batch(active_jobs, batch_id = nil)
          if batch_id.present?
            job_rows = active_jobs.map do |job|
              attributes_from_active_job(job).merge(batch_id: batch_id)
            end
            insert_all(job_rows)
            where(active_job_id: active_jobs.map(&:job_id))
          else
            create_all_from_active_jobs_without_batch(active_jobs)
          end
        end
      end

      def in_batch?
        batch_id.present?
      end

      def batch_siblings
        return Job.none unless in_batch?

        self.class.in_batch(batch_id).where.not(id: id)
      end

      def batch_position
        return nil unless in_batch?

        batch.jobs.where("id <= ?", id).count
      end

      private
        def notify_batch_if_finished
          return unless saved_change_to_finished_at? && finished_at.present?
          return unless batch.present?

          # Use perform_later to avoid holding locks
          BatchUpdateJob.perform_later(batch_id, id)
        rescue => e
          Rails.logger.error "[SolidQueue] Failed to notify batch #{batch_id} about job #{id} completion: #{e.message}"
        end
    end
  end
end
