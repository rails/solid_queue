# frozen_string_literal: true

module SolidQueue
  class ForkSupervisor < Supervisor
    def initialize(...)
      @starting_processes = {}
      super
    end

    private

    attr_reader :starting_processes

    def perform_graceful_termination
      term_forks

      Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_processes_terminated? }) do
        reap_terminated_forks
      end
    end

    def perform_immediate_termination
      quit_forks
    ensure
      close_startup_pipes
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

      check_process_startups
    end

    def reap_terminated_forks
      loop do
        pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
        break unless pid

        if (terminated_fork = process_instances.delete(pid)) && (!status.exited? || status.exitstatus.to_i > 0)
          error = Processes::ProcessExitError.new(status)
          release_claimed_jobs_by(terminated_fork, with_error: error)
        end

        close_startup_pipe(pid)
        configured_processes.delete(pid)
      end
    rescue SystemCallError
      # All children already reaped
    end

    def replace_fork(pid, status)
      SolidQueue.instrument(:replace_fork, supervisor_pid: ::Process.pid, pid: pid, status: status) do |payload|
        if terminated_fork = process_instances.delete(pid)
          close_startup_pipe(pid)
          payload[:fork] = terminated_fork
          error = Processes::ProcessExitError.new(status)
          release_claimed_jobs_by(terminated_fork, with_error: error)

          start_process(configured_processes.delete(pid))
        end
      end
    end

    def all_processes_terminated?
      process_instances.empty?
    end

    def start_process(configured_process)
      reader, writer = IO.pipe
      inherited_readers = starting_processes.values.map { |startup| startup[:reader] }
      on_fork_ready = proc do
        inherited_readers.each(&:close)
        reader.close
        writer.write(".")
      rescue Errno::EPIPE
        # The supervisor stopped waiting while this process finished booting.
      ensure
        writer.close
      end
      process_id = super(configured_process, on_fork_ready:)
      writer.close
      starting_processes[process_id] = { reader:, started_at: monotonic_time_now }
      process_id
    rescue Exception
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      raise
    end

    def check_process_startups
      starting_processes.delete_if do |pid, startup|
        reader = startup[:reader]

        # A byte means boot completed; EOF means the child exited and waitpid will replace it.
        if reader.read_nonblock(1, exception: false) != :wait_readable
          reader.close
          true
        elsif monotonic_time_now - startup[:started_at] >= SolidQueue.process_startup_timeout
          SolidQueue.instrument(:fork_startup_timeout, process: process_instances[pid], pid: pid) do
            # A child stuck in boot cannot reach its run loop to stop gracefully.
            signal_process(pid, :KILL)
          end
          reader.close
          true
        end
      end
    end

    def close_startup_pipe(pid)
      starting_processes.delete(pid)&.fetch(:reader)&.close
    end

    def close_startup_pipes
      starting_processes.each_value { |startup| startup[:reader].close }
      starting_processes.clear
    end

    def monotonic_time_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
