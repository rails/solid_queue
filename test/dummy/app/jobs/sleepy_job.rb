class SleepyJob < ApplicationJob
  queue_as :background

  retry_on Exception, wait: 30.seconds, attempts: 5

  def perform(seconds_to_sleep)
    Rails.logger.info "Feeling #{seconds_to_sleep} seconds sleepy..."
    sleep seconds_to_sleep
  end
end
