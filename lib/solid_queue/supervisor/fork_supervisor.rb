# frozen_string_literal: true

module SolidQueue
  class Supervisor::ForkSupervisor < Supervisor
    def initialize(*)
      super

      @forks = {}
      @configured_processes = {}
    end

    def kind
      "Supervisor(fork)"
    end

    private
      attr_reader :forks, :configured_processes

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

      def supervised_processes
        forks.keys
      end

      def supervise
        loop do
          break if stopped?

          set_procline
          process_signal_queue

          unless stopped?
            reap_and_replace_terminated_forks
            interruptible_sleep(1.second)
          end
        end
      ensure
        shutdown
      end

      def perform_graceful_termination
        term_forks

        Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_processes_terminated? }) do
          reap_terminated_forks
        end
      end

      def perform_immediate_termination
        quit_forks
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

      def handle_claimed_jobs_by(terminated_fork, status)
        if registered_process = process.supervisees.find_by(name: terminated_fork.name)
          error = Processes::ProcessExitError.new(status)
          registered_process.fail_all_claimed_executions_with(error)
        end
      end

      def all_processes_terminated?
        forks.empty?
      end
  end
end
