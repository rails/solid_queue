class SolidQueue::Process < ActiveRecord::Base
  include Prunable

  HEARTBEAT_INTERVAL = 60.seconds
  ALIVE_THRESHOLD = HEARTBEAT_INTERVAL * 5

  serialize :metadata, JSON

  has_many :claimed_executions

  after_destroy -> { claimed_executions.release_all }

  def self.register(metadata)
    create!(metadata: metadata, last_heartbeat_at: Time.current)
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
