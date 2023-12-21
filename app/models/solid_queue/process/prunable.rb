# frozen_string_literal: true

module SolidQueue::Process::Prunable
  extend ActiveSupport::Concern

  included do
    scope :prunable, -> { where("last_heartbeat_at <= ?", SolidQueue.process_alive_threshold.ago) }
  end

  class_methods do
    def prune
      prunable.non_blocking_lock.find_in_batches(batch_size: 50) do |batch|
        batch.each do |process|
          SolidQueue.logger.info("[SolidQueue] Pruning dead process #{process.id} - #{process.metadata}")
          process.deregister
        end
      end
    end
  end
end
