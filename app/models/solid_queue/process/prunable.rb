# frozen_string_literal: true

module SolidQueue
  class Process
    module Prunable
      extend ActiveSupport::Concern

      included do
        scope :prunable, -> { where(last_heartbeat_at: ..SolidQueue.process_alive_threshold.ago) }
      end

      class_methods do
        def prune(excluding: nil)
          SolidQueue.instrument :prune_processes, size: 0 do |payload|
            prunable.excluding(excluding).non_blocking_lock.find_in_batches(batch_size: 50) do |batch|
              payload[:size] += batch.size

              batch.each(&:prune)
            end
          end
        end
      end

      def prune
        error = Processes::ProcessPrunedError.new(last_heartbeat_at)
        fail_all_claimed_executions_with(error)

        deregister(pruned: true)
      end
    end
  end
end
