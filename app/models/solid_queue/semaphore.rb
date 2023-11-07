class SolidQueue::Semaphore < SolidQueue::Record
  scope :available, -> { where("value > 0") }
  scope :locked, -> { where(value: 0) }

  class << self
    def wait_for(concurrency_key, limit)
      if semaphore = find_by(concurrency_key: concurrency_key)
        semaphore.value > 0 && attempt_decrement(concurrency_key)
      else
        attempt_creation(concurrency_key, limit)
      end
    end

    def release(concurrency_key, concurrency_limit)
      attempt_increment(concurrency_key, concurrency_limit)
    end

    private
      def attempt_creation(concurrency_key, limit)
        create!(concurrency_key: concurrency_key, value: limit - 1)
        true
      rescue ActiveRecord::RecordNotUnique
        attempt_decrement(concurrency_key)
      end

      def attempt_decrement(concurrency_key)
        available.where(concurrency_key: concurrency_key).update_all("value = value - 1") > 0
      end

      def attempt_increment(concurrency_key, limit)
        where("value < ?", limit).where(concurrency_key: concurrency_key).update_all("value = value + 1") > 0
      end
  end
end
