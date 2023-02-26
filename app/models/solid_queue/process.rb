class SolidQueue::Process < ActiveRecord::Base
  HEARTBEAT_INTERVAL = 60.seconds
  ALIVE_THRESHOLD = HEARTBEAT_INTERVAL * 5

  scope :prunable, -> { where("last_heartbeat_at <= ?", ALIVE_THRESHOLD.ago) }

  class << self
    def register(name)
      create!(name: name, last_heartbeat_at: Time.current)
    end

    def registered?(name)
      exists?(name: name)
    end

    def deregister(name)
      find_by(name: name)&.deregister
    end

    def prune
      prunable.each do |process|
        SolidQueue.logger.info("[SolidQueue] Prunning dead process #{process.id} - #{process.name}")
        process.deregister
      end
    end
  end

  def heartbeat
    touch(:last_heartbeat_at)
  end

  def deregister
    destroy!
  end
end
