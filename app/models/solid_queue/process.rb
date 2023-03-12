class SolidQueue::Process < ActiveRecord::Base
  HEARTBEAT_INTERVAL = 60.seconds
  ALIVE_THRESHOLD = HEARTBEAT_INTERVAL * 5

  serialize :metadata, JSON

  scope :prunable, -> { where("last_heartbeat_at <= ?", ALIVE_THRESHOLD.ago) }
  has_many :claimed_executions

  after_destroy -> { claimed_executions.release_all }

  class << self
    def register(metadata)
      create!(metadata: metadata, last_heartbeat_at: Time.current)
    end

    def prune
      prunable.lock("FOR UPDATE SKIP LOCKED").find_in_batches(batch_size: 50) do |batch|
        batch.each do |process|
          SolidQueue.logger.info("[SolidQueue] Pruning dead process #{process.id} - #{process.metadata}")
          process.deregister
        end
      end
    end
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
