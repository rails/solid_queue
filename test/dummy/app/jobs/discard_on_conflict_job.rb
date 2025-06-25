class DiscardOnConflictJob < ApplicationJob
  limits_concurrency to: 1, key: ->(value) { value }, on_conflict: :discard

  def perform(value)
    Rails.logger.info "Performing DiscardOnConflictJob with value: #{value}"
  end
end
