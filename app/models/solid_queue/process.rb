class SolidQueue::Process < ActiveRecord::Base
  HEARTBEAT_INTERVAL = 60.seconds
  ALIVE_THRESHOLD = (HEARTBEAT_INTERVAL * 5).ago

  scope :prunable, -> { where("last_heartbeat_at <= ?", ALIVE_THRESHOLD) }

  class << self
    def register(name)
      create!(name: name, last_heartbeat_at: Time.current)
    end

    def registered?(name)
      exists?(name: name)
    end

    def deregister(name)
      find_by(name: name)&.destroy!
    end
  end

  def heartbeat
    touch(:last_heartbeat_at)
  end
end
