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

      check_boot_timeouts
    end

    def check_boot_timeouts
      process_instances.each do |pid, instance|
        terminate_unready_process(pid) if instance.boot_timed_out?
      end
    end

    def terminate_unready_process(pid)
      SolidQueue.instrument(:fork_boot_timeout, process: process_instances[pid], pid: pid) do
        # A child stuck in boot cannot reach its run loop to stop gracefully
        signal_process(pid, :KILL)
      end
    end

    def reap_terminated_forks
      loop do
        pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
        break unless pid

        if terminated_fork = process_instances.delete(pid)
          terminated_fork.mark_as_reaped

          if !status.exited? || status.exitstatus.to_i > 0
            attempt_to_release_claimed_jobs_by(terminated_fork, status)
          end
        end

        configured_processes.delete(pid)
      end
    rescue SystemCallError
      # All children already reaped
    end

    def replace_fork(pid, status)
      SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
        if terminated_fork = process_instances.delete(pid)
          terminated_fork.mark_as_reaped
          payload[:fork] = terminated_fork

          attempt_to_release_claimed_jobs_by(terminated_fork, status)

          start_process(configured_processes.delete(pid))
        end
      end
    end

    # The database may be unreachable — likely the same reason the fork
    # terminated. Neither starting a replacement nor shutting down can depend
    # on it: the jobs claimed by the terminated fork will be failed when its
    # stale registration is pruned once the database is back.
    def attempt_to_release_claimed_jobs_by(terminated_fork, status)
      release_claimed_jobs_by(terminated_fork, with_error: Processes::ProcessExitError.new(status))
    rescue StandardError => error
      handle_thread_error(error)
    end

    def all_processes_terminated?
      process_instances.empty?
    end
  end
end
