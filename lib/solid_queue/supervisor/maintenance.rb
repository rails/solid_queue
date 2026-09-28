module SolidQueue
  module Supervisor::Maintenance
    extend ActiveSupport::Concern

    included do
      after_boot :fail_orphaned_executions
    end

    # How far past its own interval a maintenance run is allowed to go before we
    # treat it as stalled rather than slow. One full missed cycle of slack.
    STALL_FACTOR = 2

    private
      def launch_maintenance_task
        @last_maintenance_returned_at = Concurrent::AtomicReference.new(SolidQueue::Timer.monotonic_time_now)

        @maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) do
          prune_dead_processes
        end

        @maintenance_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @maintenance_task.execute

        launch_maintenance_watchdog
      end

      # Pruning is how a supervisor notices dead processes, and it runs in a
      # Concurrent::TimerTask, which reschedules only once its task returns. A
      # prune blocked on an unresponsive database therefore stops this supervisor
      # pruning ever again, silently -- the mechanism meant to notice dead
      # processes is built from the same material as the processes it watches.
      #
      # A supervisor cannot replace itself, so stop instead, and leave it to
      # whatever runs this supervisor to start a new one.
      #
      # The watchdog ticks at the heartbeat interval - not that heartbeats are
      # involved, but any working configuration already keeps that cadence well
      # inside the alive threshold, so a stall is noticed at most one tick
      # after it crosses the line.
      def launch_maintenance_watchdog
        @maintenance_watchdog_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          stop_to_be_replaced if maintenance_stalled?
        end

        @maintenance_watchdog_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @maintenance_watchdog_task.execute
      end

      def stop_maintenance_task
        @maintenance_task&.shutdown
        @maintenance_watchdog_task&.shutdown
      end

      # Whether maintenance has stopped returning altogether, as opposed to
      # failing: a prune that raises is reported by the task's observer.
      def maintenance_stalled?
        SolidQueue::Timer.monotonic_time_now - @last_maintenance_returned_at.get >
          STALL_FACTOR * SolidQueue.process_alive_threshold
      end

      def prune_dead_processes
        wrap_in_app_executor { SolidQueue::Process.prune(excluding: process) }
      ensure
        @last_maintenance_returned_at.set(SolidQueue::Timer.monotonic_time_now)
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
