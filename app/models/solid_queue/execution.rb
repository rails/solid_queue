# frozen_string_literal: true

module SolidQueue
  class Execution < Record
    class UndiscardableError < StandardError; end

    include JobAttributes

    self.abstract_class = true

    scope :ordered, -> { order(priority: :asc, job_id: :asc) }

    belongs_to :job

    class << self
      def create_all_from_jobs(jobs)
        insert_all execution_data_from_jobs(jobs)
      end

      def execution_data_from_jobs(jobs)
        jobs.collect do |job|
          attributes_from_job(job).merge(job_id: job.id)
        end
      end
    end

    def discard
      with_lock do
        job.destroy
        destroy
      end
    end
  end
end
