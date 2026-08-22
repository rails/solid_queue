# frozen_string_literal: true

class SolidQueue::Process < SolidQueue::Record
  include Executor, Prunable

  belongs_to :supervisor, class_name: "SolidQueue::Process", optional: true, inverse_of: :supervisees
  has_many :supervisees, class_name: "SolidQueue::Process", inverse_of: :supervisor, foreign_key: :supervisor_id

  store :metadata, coder: JSON

  def self.register(**attributes)
    SolidQueue.instrument :register_process, **attributes do |payload|
      create!(attributes.merge(last_heartbeat_at: Time.current)).tap do |process|
        payload[:process_id] = process.id
      end
    rescue Exception => error
      payload[:error] = error
      raise
    end
  end

  def heartbeat
    # Clear any previous changes before locking, for example, in case a previous heartbeat
    # failed because of a DB issue and we still have the unpersisted value
    restore_attributes
    with_lock { touch(:last_heartbeat_at) }
  rescue
    # touch writes the attribute before persisting; don't let a failed
    # update leave this object claiming a heartbeat that was never persisted
    restore_attributes
    raise
  end

  def deregister(pruned: false)
    SolidQueue.instrument :deregister_process, process: self, pruned: pruned do |payload|
      destroy!

      unless supervised? || pruned
        supervisees.each(&:deregister)
      end
    rescue Exception => error
      payload[:error] = error
      raise
    end
  end

  private
    def supervised?
      supervisor_id.present?
    end
end
