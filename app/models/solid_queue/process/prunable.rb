# frozen_string_literal: true

module SolidQueue::Process::Prunable
  extend ActiveSupport::Concern

  included do
    scope :prunable, -> { where(last_heartbeat_at: ..SolidQueue.process_alive_threshold.ago) }
  end

  class_methods do
    def prune
      SolidQueue.instrument :prune_processes, size: 0 do |payload|
        prunable.non_blocking_lock.find_in_batches(batch_size: 50) do |batch|
          payload[:size] += batch.size

          batch.each { |process| process.deregister(pruned: true) }
        end
      end
    end
  end
end
