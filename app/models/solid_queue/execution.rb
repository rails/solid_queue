# frozen_string_literal: true

module SolidQueue
  class Execution < Record
    include JobAttributes

    self.abstract_class = true

    scope :ordered, -> { order(priority: :asc, job_id: :asc) }

    belongs_to :job

    alias_method :discard, :destroy

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
  end
end
