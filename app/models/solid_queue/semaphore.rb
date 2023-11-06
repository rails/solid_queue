class SolidQueue::Semaphore < SolidQueue::Record
  scope :available, -> { where("value > 0") }
  scope :locked, -> { where(value: 0) }

  class << self
    def wait_for(identifier, limit)
      if semaphore = find_by(identifier: identifier)
        semaphore.value > 0 && attempt_decrement(identifier)
      else
        attempt_creation(identifier, limit)
      end
    end

    def release(identifier, concurrency_limit)
      attempt_increment(identifier, concurrency_limit)
    end

    private
      def attempt_creation(identifier, limit)
        create!(identifier: identifier, value: limit - 1)
        true
      rescue ActiveRecord::RecordNotUnique
        attempt_decrement(identifier)
      end

      def attempt_decrement(identifier)
        available.where(identifier: identifier).update_all("value = value - 1") > 0
      end

      def attempt_increment(identifier, limit)
        where("value < ?", limit).where(identifier: identifier).update_all("value = value + 1") > 0
      end
  end
end
