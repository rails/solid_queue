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

      # When a supervised process crashes or exits we need to mark all the
      # executions it had claimed as failed so that they can be retried
      # by some other worker.
      def release_claimed_jobs_by(terminated_process, with_error:)
        wrap_in_app_executor do
          if registered_process = SolidQueue::Process.find_by(name: terminated_process.name)
            registered_process.fail_all_claimed_executions_with(with_error)
          end
        end
      end

      # The database may be unreachable — possibly the same reason the
      # supervised process died. Neither starting a replacement nor shutting
      # down can depend on it: the jobs claimed by the dead process will be
      # failed when its stale registration is pruned once the database is back.
      def attempt_to_release_claimed_jobs_by(terminated_process, with_error:)
        release_claimed_jobs_by(terminated_process, with_error: with_error)
      rescue StandardError => error
        handle_thread_error(error)
      end
  end
end
