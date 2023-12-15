# frozen_string_literal: true

class SolidQueue::Semaphore < SolidQueue::Record
  scope :available, -> { where("value > 0") }
  scope :expired, -> { where(expires_at: ...Time.current) }

  class << self
    def wait(job)
      Proxy.new(job, self).wait
    end

    def signal(job)
      Proxy.new(job, self).signal
    end
  end

  class Proxy
    def initialize(job, proxied_class)
      @job = job
      @proxied_class = proxied_class
    end

    def wait
      if semaphore = proxied_class.find_by(key: key)
        semaphore.value > 0 && attempt_decrement
      else
        attempt_creation
      end
    end

    def signal
      attempt_increment
    end

    private
      attr_reader :job, :proxied_class

      def attempt_creation
        proxied_class.create!(key: key, value: limit - 1, expires_at: expires_at)
        true
      rescue ActiveRecord::RecordNotUnique
        attempt_decrement
      end

      def attempt_decrement
        proxied_class.available.where(key: key).update_all([ "value = value - 1, expires_at = ?", expires_at ]) > 0
      end

      def attempt_increment
        proxied_class.where(key: key, value: ...limit).update_all([ "value = value + 1, expires_at = ?", expires_at ]) > 0
      end

      def key
        job.concurrency_key
      end

      def expires_at
        job.concurrency_duration.from_now
      end

      def limit
        job.concurrency_limit
      end
  end
end
