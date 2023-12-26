# frozen_string_literal: true

class SolidQueue::FailedExecution < SolidQueue::Execution
  serialize :error, coder: JSON

  before_create :expand_error_details_from_exception

  attr_accessor :exception

  def retry
    transaction do
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
