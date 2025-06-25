class LimitedDiscardJob < ApplicationJob
  limits_concurrency to: 2, key: ->(group, id) { group }, on_conflict: :discard

  def perform(group, id)
    Rails.logger.info "Performing LimitedDiscardJob with group: #{group}, id: #{id}"
    sleep 0.1
  end
end
