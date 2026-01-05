# frozen_string_literal: true

module SolidQueue
  class AsyncSupervisor < Supervisor
    after_shutdown :terminate_gracefully, unless: :standalone?

    def stop
      super
      @thread&.join
    end

    private
      def supervise
        if standalone? then super
        else
          @thread = create_thread { super }
        end
      end

      def check_and_replace_terminated_processes
        terminated_threads = process_instances.select { |thread_id, instance| !instance.alive? }
        terminated_threads.each { |thread_id, instance| replace_thread(thread_id, instance) }
      end

      def replace_thread(thread_id, instance)
        SolidQueue.instrument(:replace_thread, supervisor_pid: ::Process.pid) do |payload|
          payload[:thread] = instance

          error = Processes::ThreadTerminatedError.new(terminated_instance.name)
          release_claimed_jobs_by(terminated_instance, with_error: error)

          start_process(configured_processes.delete(thread_id))
        end
      end

      def perform_graceful_termination
        process_instances.values.each(&:stop)

        Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_processes_terminated? })
      end

      def perform_immediate_termination
        exit!
      end

      def all_processes_terminated?
        process_instances.values.none?(&:alive?)
      end
  end
end
