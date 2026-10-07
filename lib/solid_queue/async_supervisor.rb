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
        terminated_threads.each { |thread_id, _| replace_thread(thread_id) }
      end

      def replace_thread(thread_id)
        SolidQueue.instrument(:replace_thread, supervisor_pid: ::Process.pid) do |payload|
          if (instance = process_instances.delete(thread_id))
            payload[:thread] = instance

            attempt_to_release_claimed_jobs_by(instance, with_error: Processes::ThreadTerminatedError.new(instance.name))

            start_process(configured_processes.delete(thread_id))
          end
        end
      end

      def perform_graceful_termination
        process_instances.values.each(&:stop)

        Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_processes_terminated? })

        # The exit! that follows skips the shutdown callbacks, so release the jobs
        # of the threads still running now instead of leaving them to be pruned
        attempt_to_deregister unless all_processes_terminated?
      end

      def perform_immediate_termination
        exit!
      end

      def attempt_to_deregister
        wrap_in_app_executor do
          # Not our own copy: it shares the threads' registrations in memory, and
          # those of threads that already deregistered are destroyed and frozen
          SolidQueue::Process.find_by(id: process_id)&.deregister
        end
      rescue StandardError => error
        handle_thread_error(error)
      end

      def all_processes_terminated?
        process_instances.values.none?(&:alive?)
      end
  end
end
