# frozen_string_literal: true

module SolidQueue
  class AsyncSupervisor < Supervisor
    private
      attr_reader :threads

      def start_processes
        @threads = {}

        configuration.configured_processes.each { |configured_process| start_process(configured_process) }
      end

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
          instance.mode = :async
        end

        thread = Thread.new do
          begin
            process_instance.start
          rescue Exception => e
            puts "Error in thread: #{e.message}"
            puts e.backtrace
          end
        end
        threads[thread] = [ process_instance, configured_process ]
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do |payload|
          processes.each(&:stop)

          Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_threads_terminated? }) do
            # No-op, we just wait
          end

          unless all_threads_terminated?
            payload[:shutdown_timeout_exceeded] = true
            terminate_immediately
          end
        end
      end

      def terminate_immediately
        SolidQueue.instrument(:immediate_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do
          threads.keys.each(&:kill)
        end
      end

      def supervised_processes
        processes.map(&:to_s)
      end

      def reap_and_replace_terminated_forks
        # No-op in async mode, we'll check for dead threads in the supervise loop
      end

      def all_threads_terminated?
        threads.keys.all? { |thread| !thread.alive? }
      end

      def supervise
        loop do
          break if stopped?

          set_procline
          process_signal_queue

          unless stopped?
            check_and_replace_terminated_threads
            interruptible_sleep(1.second)
          end
        end
      ensure
        shutdown
      end

      def check_and_replace_terminated_threads
        terminated_threads = {}
        threads.each do |thread, (process, configured_process)|
          unless thread.alive?
            terminated_threads[thread] = configured_process
          end
        end

        terminated_threads.each do |thread, configured_process|
          threads.delete(thread)
          start_process(configured_process)
        end
      end

      def processes
        threads.values.map(&:first)
      end
  end
end