# frozen_string_literal: true

module SolidQueue
  class ForkSupervisor < Supervisor
    private
      attr_reader :forks, :configured_processes

      def start_processes
        @forks = {}
        @configured_processes = {}

        configuration.configured_processes.each { |configured_process| start_process(configured_process) }
      end

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
          instance.mode = :fork
        end

        pid = fork do
          process_instance.start
        end

        configured_processes[pid] = configured_process
        forks[pid] = process_instance
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do |payload|
          term_forks

          Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_forks_terminated? }) do
            reap_terminated_forks
          end

          unless all_forks_terminated?
            payload[:shutdown_timeout_exceeded] = true
            terminate_immediately
          end
        end
      end

      def terminate_immediately
        SolidQueue.instrument(:immediate_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do
          quit_forks
        end
      end

      def supervised_processes
        forks.keys
      end

      def term_forks
        signal_processes(forks.keys, :TERM)
      end

      def quit_forks
        signal_processes(forks.keys, :QUIT)
      end

      def reap_and_replace_terminated_forks
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          replace_fork(pid, status)
        end
      end

      def reap_terminated_forks
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          if (terminated_fork = forks.delete(pid)) && (!status.exited? || status.exitstatus > 0)
            handle_claimed_jobs_by(terminated_fork, status)
          end

          configured_processes.delete(pid)
        end
      rescue SystemCallError
        # All children already reaped
      end

      def replace_fork(pid, status)
        SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
          if terminated_fork = forks.delete(pid)
            payload[:fork] = terminated_fork
            handle_claimed_jobs_by(terminated_fork, status)

            start_process(configured_processes.delete(pid))
          end
        end
      end

      # When a supervised fork crashes or exits we need to mark all the
      # executions it had claimed as failed so that they can be retried
      # by some other worker.
      def handle_claimed_jobs_by(terminated_fork, status)
        wrap_in_app_executor do
          if registered_process = SolidQueue::Process.find_by(name: terminated_fork.name)
            error = Processes::ProcessExitError.new(status)
            registered_process.fail_all_claimed_executions_with(error)
          end
        end
      end

      def all_forks_terminated?
        forks.empty?
      end
  end
end
