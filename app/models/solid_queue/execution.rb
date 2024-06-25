# frozen_string_literal: true

module SolidQueue
  class Execution < Record
    class UndiscardableError < StandardError; end

    include JobAttributes

    self.abstract_class = true

    scope :ordered, -> { order(priority: :asc, job_id: :asc) }

    belongs_to :job

    class << self
      def type
        model_name.element.sub("_execution", "").to_sym
      end

      def create_all_from_jobs(jobs)
        insert_all execution_data_from_jobs(jobs)
      end

      def execution_data_from_jobs(jobs)
        jobs.collect do |job|
          attributes_from_job(job).merge(job_id: job.id)
        end
      end

      def discard_all_in_batches(batch_size: 500)
        pending = count
        discarded = 0

        SolidQueue.instrument(:discard_all, batch_size: batch_size, status: type, batches: 0, size: 0) do |payload|
          loop do
            transaction do
              job_ids = limit(batch_size).order(:job_id).lock.pluck(:job_id)
              discarded = discard_jobs job_ids

              where(job_id: job_ids).delete_all
              pending -= discarded

              payload[:size] += discarded
              payload[:batches] += 1
            end

            break if pending <= 0 || discarded == 0
          end
        end
      end

      def discard_all_from_jobs(jobs)
        SolidQueue.instrument(:discard_all, jobs_size: jobs.size, status: type) do |payload|
          transaction do
            job_ids = lock_all_from_jobs(jobs)

            payload[:size] = discard_jobs job_ids
            where(job_id: job_ids).delete_all
          end
        end
      end

      private
        def lock_all_from_jobs(jobs)
          where(job_id: jobs.map(&:id)).order(:job_id).lock.pluck(:job_id)
        end

        def discard_jobs(job_ids)
          Job.where(id: job_ids).delete_all
        end
    end

    def type
      self.class.type
    end

    def discard
      SolidQueue.instrument(:discard, job_id: job_id, status: type) do
        with_lock do
          job.destroy
          destroy
        end
      end
    end
  end
end
