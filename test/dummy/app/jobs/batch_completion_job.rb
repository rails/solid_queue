class BatchCompletionJob < ApplicationJob
  queue_as :background

  def perform(batch)
    Rails.logger.info "#{batch.jobs.size} jobs completed!"
  end
end
