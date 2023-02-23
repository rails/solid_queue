module SolidQueue::Job::Executable
  extend ActiveSupport::Concern

  included do
    has_one :ready_execution
    has_one :claimed_execution
    has_one :failed_execution

    has_one :scheduled_execution

    after_save :prepare_for_execution
  end

  STATUSES = %w[ ready claimed failed scheduled ]

  STATUSES.each do |status|
    define_method("#{status}?") { public_send("#{status}_execution").present? }
  end

  def prepare_for_execution
    if due?
      create_ready_execution!
    else
      create_scheduled_execution!
    end
  end

  def finished
    touch(:finished_at)
  end

  def finished?
    finished_at.present?
  end

  def failed_with(exception)
    create_failed_execution!(exception: exception)
  end

  private
    def due?
      scheduled_at.nil? || scheduled_at <= Time.current
    end
end
