class SolidQueue::Semaphore < SolidQueue::Record
  scope :available, -> { where("value > 0") }
  scope :locked, -> { where(value: 0) }
  scope :expired, -> { where(expires_at: ...Time.current)}

  class << self
    def wait(job)
      if semaphore = find_by(key: job.concurrency_key)
        semaphore.value > 0 && attempt_decrement(job.concurrency_key, job.concurrency_limit_duration)
      else
        attempt_creation(job.concurrency_key, job.concurrency_limit, job.concurrency_limit_duration)
      end
    end

    def signal(job)
      attempt_increment(job.concurrency_key, job.concurrency_limit, job.concurrency_limit_duration)
    end

    private
      def attempt_creation(key, limit, duration)
        create!(key: key, value: limit - 1, expires_at: duration.from_now)
        true
      rescue ActiveRecord::RecordNotUnique
        attempt_decrement(key, duration)
      end

      def attempt_decrement(key, duration)
        available.where(key: key).update_all([ "value = value - 1, expires_at = ?", duration.from_now ]) > 0
      end

      def attempt_increment(key, limit, duration)
        where("value < ?", limit).where(key: key).update_all([ "value = value + 1, expires_at = ?", duration.from_now ]) > 0
      end
  end
end
