module SolidQueue::Job::Executable
  extend ActiveSupport::Concern

  included do
    has_one :ready_execution
    has_one :claimed_execution
    has_one :failed_execution

    after_save :prepare_for_execution, if: :due?
  end

  def prepare_for_execution
    create_ready_execution!(queue_name: queue_name, priority: priority)
  end

  def finished
    touch(:finished_at)
  end

  def failed_with(exception)
    create_failed_execution!(exception: exception)
  end

  private
    def due?
      scheduled_at <= Time.current
    end
end
