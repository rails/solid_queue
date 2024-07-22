# frozen_string_literal: true

module SolidQueue
  class Supervisor::ForkSupervisor < Supervisor
    include Signals, Single

    def initialize(*)
      super
      @forks = {}
    end

    def kind
      "Supervisor(fork)"
    end

    private
      attr_reader :forks

      def supervise
        loop do
          procline "supervising #{forks.keys.join(", ")}"

          process_signal_queue
          reap_and_replace_terminated_forks
          interruptible_sleep(1.second)
        end
      end

      def start_process(configured_process)
        configured_process.supervised_by process
        configured_process.mode = :fork

        pid = fork do
          configured_process.start
        end

        forks[pid] = configured_process
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, supervisor_pid: ::Process.pid, supervised_processes: forks.keys) do |payload|
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
        SolidQueue.instrument(:immediate_termination, supervisor_pid: ::Process.pid, supervised_processes: forks.keys) do
          quit_forks
        end
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

          forks.delete(pid)
        end
      rescue SystemCallError
        # All children already reaped
      end

      def replace_fork(pid, status)
        SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
          if supervised_fork = forks.delete(pid)
            payload[:fork] = supervised_fork
            start_process(supervised_fork)
          end
        end
      end

      def all_forks_terminated?
        forks.empty?
      end
  end
end
