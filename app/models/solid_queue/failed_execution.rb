# frozen_string_literal: true

module SolidQueue
  class FailedExecution < Execution
    include Dispatching

    serialize :error, coder: JSON

    before_create :expand_error_details_from_exception

    attr_accessor :exception

    class << self
      def retry_all(jobs)
        transaction do
          retriable_job_ids = where(job_id: jobs.map(&:id)).order(:job_id).lock.pluck(:job_id)
          dispatch_batch(retriable_job_ids)
        end
      end
    end

    def retry
      with_lock do
        job.prepare_for_execution
        destroy!
      end
    end

    %i[ exception_class message backtrace ].each do |attribute|
      define_method(attribute) { error.with_indifferent_access[attribute] }
    end

    private
      def expand_error_details_from_exception
        if exception
          self.error = { exception_class: exception.class.name, message: exception.message, backtrace: exception.backtrace }
        end
      end
    end
end
