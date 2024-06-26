module SolidQueue
  module Supervisor::Maintenance
    extend ActiveSupport::Concern

      private
        def launch_maintenance_task
          @maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) do
            prune_dead_processes
            release_orphaned_executions
          end
          @maintenance_task.execute
        end

        def stop_maintenance_task
          @maintenance_task&.shutdown
        end

        def prune_dead_processes
          wrap_in_app_executor { SolidQueue::Process.prune }
        end

        def release_orphaned_executions
          wrap_in_app_executor { SolidQueue::ClaimedExecution.orphaned.release_all }
        end
    end
end
