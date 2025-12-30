# frozen_string_literal: true

module SolidQueue
  class ForkSupervisor < Supervisor
    private

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
      signal_processes(process_instances.keys, :TERM)
    end

    def quit_forks
      signal_processes(process_instances.keys, :QUIT)
    end

    def check_and_replace_terminated_processes
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

        if (terminated_fork = process_instances.delete(pid)) && !status.exited? || status.exitstatus > 0
          handle_claimed_jobs_by(terminated_fork, status)
        end

        configured_processes.delete(pid)
      end
    rescue SystemCallError
      # All children already reaped
    end

    def replace_fork(pid, status)
      SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
        if terminated_fork = process_instances.delete(pid)
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

    def all_processes_terminated?
      process_instances.empty?
    end
  end
end
