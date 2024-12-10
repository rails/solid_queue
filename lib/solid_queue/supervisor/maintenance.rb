module SolidQueue
  module Supervisor::Maintenance
    extend ActiveSupport::Concern

    included do
      after_boot :fail_orphaned_executions
    end

    private

      def launch_maintenance_task
        @maintenance_task = SolidQueue::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) do
          prune_dead_processes
        end
      end

      def stop_maintenance_task
        @maintenance_task&.shutdown
      end

      def prune_dead_processes
        wrap_in_app_executor { SolidQueue::Process.prune(excluding: process) }
      end

      def fail_orphaned_executions
        wrap_in_app_executor do
          ClaimedExecution.orphaned.fail_all_with(Processes::ProcessMissingError.new)
        end
      end
  end
end
