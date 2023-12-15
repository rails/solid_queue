# frozen_string_literal: true

class SolidQueue::Process < SolidQueue::Record
  include Prunable

  belongs_to :supervisor, class_name: "SolidQueue::Process", optional: true, inverse_of: :forks
  has_many :forks, class_name: "SolidQueue::Process", inverse_of: :supervisor, foreign_key: :supervisor_id, dependent: :destroy
  has_many :claimed_executions

  store :metadata, coder: JSON

  after_destroy -> { claimed_executions.release_all }

  def self.register(**attributes)
    create!(attributes.merge(last_heartbeat_at: Time.current))
  end

  def heartbeat
    touch(:last_heartbeat_at)
  end

  def deregister
    destroy!
  rescue Exception
    SolidQueue.logger.error("[SolidQueue] Error deregistering process #{id} - #{metadata}")
    raise
  end
end
