class SolidQueue::Semaphore < SolidQueue::Record
  scope :available, -> { where("value > 0") }
  scope :locked, -> { where(value: 0) }

  class << self
    def wait_for(concurrency_key, limit, duration)
      if semaphore = find_by(concurrency_key: concurrency_key)
        semaphore.value > 0 && attempt_decrement(concurrency_key, duration)
      else
        attempt_creation(concurrency_key, limit, duration)
      end
    end

    def release(concurrency_key, limit, duration)
      attempt_increment(concurrency_key, limit, duration)
    end

    private
      def attempt_creation(concurrency_key, limit, duration)
        create!(concurrency_key: concurrency_key, value: limit - 1, expires_at: duration.from_now)
        true
      rescue ActiveRecord::RecordNotUnique
        attempt_decrement(concurrency_key, duration)
      end

      def attempt_decrement(concurrency_key, duration)
        available.where(concurrency_key: concurrency_key).update_all([ "value = value - 1, expires_at = ?", duration.from_now ]) > 0
      end

      def attempt_increment(concurrency_key, limit, duration)
        where("value < ?", limit).where(concurrency_key: concurrency_key).update_all([ "value = value + 1, expires_at = ?", duration.from_now ]) > 0
      end
  end
end
