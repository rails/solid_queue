# frozen_string_literal: true

module SolidQueue::Processes
  module Registrable
    extend ActiveSupport::Concern

    included do
      after_boot :register, :launch_heartbeat

      after_shutdown :stop_heartbeat, :deregister
    end

    def process_id
      process&.id
    end

    private
      attr_accessor :process

      def register
        wrap_in_app_executor do
          @process = SolidQueue::Process.register \
            kind: kind,
            name: name,
            pid: pid,
            hostname: hostname,
            supervisor: try(:supervisor),
            metadata: metadata.compact
        end
      end

      def deregister
        wrap_in_app_executor { process&.deregister }
      end

      def registered?
        process.present?
      end

      def launch_heartbeat
        @last_heartbeat_returned_at = Concurrent::AtomicReference.new(SolidQueue::Timer.monotonic_time_now)

        @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          wrap_in_app_executor { heartbeat }
        end

        @heartbeat_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @heartbeat_task.execute

        launch_heartbeat_watchdog
      end

      # A heartbeat that raises is handled below, but one that never returns is not.
      # Concurrent::TimerTask reschedules a task and notifies its observers only once
      # the task has completed, so a heartbeat blocked on an unresponsive database --
      # a half-open socket to a connection pooler that stopped serving, say -- stalls
      # the heartbeat thread silently and indefinitely, and `presumed_dead?` is never
      # reached because nothing was raised.
      #
      # The watchdog's check reads nothing but memory, so it cannot block the
      # same way; the stop it sets off can still run blocking code (stop hooks,
      # for one), but only after the stall has been noticed.
      def launch_heartbeat_watchdog
        @heartbeat_watchdog_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          stop_to_be_replaced if heartbeat_stalled?
        end

        @heartbeat_watchdog_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @heartbeat_watchdog_task.execute
      end

      def stop_heartbeat
        @heartbeat_task&.shutdown
        @heartbeat_watchdog_task&.shutdown
      end

      # Whether the heartbeat has stopped returning altogether. Note this asks only
      # whether the call came back, not whether it succeeded: a heartbeat that keeps
      # raising is `presumed_dead?`'s business.
      def heartbeat_stalled?
        SolidQueue::Timer.monotonic_time_now - @last_heartbeat_returned_at.get > SolidQueue.process_alive_threshold
      end

      def heartbeat
        process&.heartbeat
      rescue ActiveRecord::RecordNotFound
        # Our registration is gone: a supervisor pruned it
        stop_to_be_replaced
      rescue => error
        # Errors like a dropped database connection prevent the
        # heartbeat from going through, and even from finding out whether the
        # registration is still there
        stop_to_be_replaced if presumed_dead?
        raise error
      ensure
        @last_heartbeat_returned_at.set(SolidQueue::Timer.monotonic_time_now)
      end

      # Whether this process's registration is prunable: if the last heartbeat that
      # we were able to persist is older than the alive threshold, supervisors
      # consider this one dead and would have pruned its registration by now
      def presumed_dead?
        process && process.last_heartbeat_at <= SolidQueue.process_alive_threshold.ago
      end

      # Deregister locally and wake the run loop, which stops when
      # unregistered, so the supervisor replaces this process
      def stop_to_be_replaced
        self.process = nil
        wake_up
      end

      def reload_metadata
        wrap_in_app_executor { process&.update(metadata: metadata.compact) }
      end
  end
end
