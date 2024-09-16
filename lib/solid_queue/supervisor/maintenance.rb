module SolidQueue
  module Supervisor::Maintenance
    extend ActiveSupport::Concern

    included do
      after_boot :fail_orphaned_executions
    end

    private
      def launch_maintenance_task
        @maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) do
          prune_dead_processes
        end

        @maintenance_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @maintenance_task.execute
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
