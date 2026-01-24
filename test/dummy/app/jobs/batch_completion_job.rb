class BatchCompletionJob < ApplicationJob
  queue_as :background

  def perform
    Rails.logger.info "#{batch.jobs.size} jobs completed!"
  end
end
