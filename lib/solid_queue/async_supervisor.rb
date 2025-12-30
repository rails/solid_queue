# frozen_string_literal: true

module SolidQueue
  class AsyncSupervisor < Supervisor
    private
      def check_and_replace_terminated_processes
        terminated_threads = process_instances.select { |thread_id, instance| !instance.alive? }
        terminated_threads.each { |thread_id, instance| replace_thread(thread_id, instance) }
      end

      def replace_thread(thread_id, instance)
        SolidQueue.instrument(:replace_thread, supervisor_pid: ::Process.pid) do |payload|
          payload[:thread] = instance
          handle_claimed_jobs_by(terminated_instance, thread)

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

      # When a supervised thread terminates unexpectedly, mark all executions
      # it had claimed as failed so they can be retried by another worker.
      def handle_claimed_jobs_by(terminated_instance, thread)
        wrap_in_app_executor do
          if registered_process = SolidQueue::Process.find_by(name: terminated_instance.name)
            error = Processes::ThreadTerminatedError.new(terminated_instance.name)
            registered_process.fail_all_claimed_executions_with(error)
          end
        end
      end
  end
end
