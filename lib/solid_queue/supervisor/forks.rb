# frozen_string_literal: true

module SolidQueue
  class Supervisor::Forks < Supervisor
    def kind
      "Supervisor(forks)"
    end

    private
      def start_process(configured_process)
        configured_process.supervised_by process
        configured_process.mode = :fork

        pid = fork do
          configured_process.start
        end

        processes[pid] = configured_process
      end

      def term_processes
        signal_processes(processes.keys, :TERM)
      end

      def quit_processes
        signal_processes(processes.keys, :QUIT)
      end

      def reap_and_replace_terminated_processes
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          replace_fork(pid, status)
        end
      end

      def reap_terminated_processes
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          processes.delete(pid)
        end
      rescue SystemCallError
        # All children already reaped
      end

      def replace_fork(pid, status)
        SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
          if supervised_fork = processes.delete(pid)
            payload[:fork] = supervised_fork
            start_process(supervised_fork)
          end
        end
      end

      def all_processes_terminated?
        processes.empty?
      end
  end
end
