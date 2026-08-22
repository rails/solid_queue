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
        @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          wrap_in_app_executor { heartbeat }
        end

        @heartbeat_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @heartbeat_task.execute
      end

      def stop_heartbeat
        @heartbeat_task&.shutdown
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
