# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Signals

    class << self
      def start(mode: :fork, load_configuration_from: nil)
        SolidQueue.supervisor = true
        configuration = Configuration.new(load_from: load_configuration_from)

        new(*configuration.processes).start
      end
    end

    def initialize(*configured_processes)
      @configured_processes = Array(configured_processes)
      @forks = {}
    end

    def start
      run_callbacks(:boot) { boot }

      start_forks
      launch_maintenance_task

      supervise
    rescue GracefulTerminationRequested
      graceful_termination
    rescue ImmediateTerminationRequested
      immediate_termination
    ensure
      run_callbacks(:shutdown) { shutdown }
    end

    private
      attr_reader :configured_processes, :forks

      def boot
        sync_std_streams
        setup_pidfile
        register_signal_handlers
      end

      def supervise
        loop do
          procline "supervising #{forks.keys.join(", ")}"

          process_signal_queue
          reap_and_replace_terminated_forks
          interruptible_sleep(1.second)
        end
      end

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end

      def setup_pidfile
        @pidfile = if SolidQueue.supervisor_pidfile
          Processes::Pidfile.new(SolidQueue.supervisor_pidfile).tap(&:setup)
        end
      end

      def start_forks
        configured_processes.each { |configured_process| start_fork(configured_process) }
      end

      def launch_maintenance_task
        @maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) do
          prune_dead_processes
          release_orphaned_executions
        end
        @maintenance_task.execute
      end

      def shutdown
        stop_process_prune
        restore_default_signal_handlers
        delete_pidfile
      end

      def graceful_termination
        SolidQueue.instrument(:graceful_termination, supervisor_pid: ::Process.pid, supervised_pids: forks.keys) do |payload|
          term_forks

          wait_until(SolidQueue.shutdown_timeout, -> { all_forks_terminated? }) do
            reap_terminated_forks
          end

          unless all_forks_terminated?
            payload[:shutdown_timeout_exceeded] = true
            immediate_termination
          end
        end
      end

      def immediate_termination
        SolidQueue.instrument(:immediate_termination, supervisor_pid: ::Process.pid, supervised_pids: forks.keys) do
          quit_forks
        end
      end

      def term_forks
        signal_processes(forks.keys, :TERM)
      end

      def quit_forks
        signal_processes(forks.keys, :QUIT)
      end

      def stop_process_prune
        @maintenance_task&.shutdown
      end

      def delete_pidfile
        @pidfile&.delete
      end

      def prune_dead_processes
        wrap_in_app_executor { SolidQueue::Process.prune }
      end

      def release_orphaned_executions
        wrap_in_app_executor { SolidQueue::ClaimedExecution.orphaned.release_all }
      end

      def start_fork(configured_process)
        configured_process.supervised_by process
        configured_process.mode = :fork

        pid = fork do
          configured_process.start
        end

        forks[pid] = configured_process
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
            start_fork(supervised_fork)
          end
        end
      end

      def all_forks_terminated?
        forks.empty?
      end

      def wait_until(timeout, condition, &block)
        if timeout > 0
          deadline = monotonic_time_now + timeout

          while monotonic_time_now < deadline && !condition.call
            sleep 0.1
            block.call
          end
        else
          while !condition.call
            sleep 0.5
            block.call
          end
        end
      end

      def monotonic_time_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
  end
end
