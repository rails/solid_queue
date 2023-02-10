class SolidQueue::FailedExecution < SolidQueue::Execution
  before_create :expand_error_details_from_exception

  attr_accessor :exception

  def retry
    transaction do
      job.prepare_for_execution
      destroy!
    end
  end

  private
    def expand_error_details_from_exception
      if exception
        self.error = ([ exception.class.name, exception.message ] + exception.backtrace).join("\n")
      end
    end
end
