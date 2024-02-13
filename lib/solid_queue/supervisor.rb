# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Processes::Signals

    set_callback :boot, :after, :launch_process_prune

    class << self
      def start(mode: :work, load_configuration_from: nil)
        SolidQueue.supervisor = true
        configuration = Configuration.new(mode: mode, load_from: load_configuration_from)

        new(*configuration.processes).start
      end
    end

    def initialize(*configured_processes)
      @configured_processes = Array(configured_processes)
      @forks = {}
    end

    def start
      run_callbacks(:boot) { boot }

      supervise
    rescue Processes::GracefulTerminationRequested
      graceful_termination
    rescue Processes::ImmediateTerminationRequested
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
        start_forks

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

      def launch_process_prune
        @prune_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) { prune_dead_processes }
        @prune_task.execute
      end

      def start_forks
        configured_processes.each { |configured_process| start_fork(configured_process) }
      end

      def shutdown
        stop_process_prune
        restore_default_signal_handlers
        delete_pidfile
      end

      def graceful_termination
        SolidQueue.logger.info("[SolidQueue] Terminating gracefully...")
        term_forks

        wait_until(SolidQueue.shutdown_timeout, -> { all_forks_terminated? }) do
          reap_terminated_forks
        end

        immediate_termination unless all_forks_terminated?
      end

      def immediate_termination
        SolidQueue.logger.info("[SolidQueue] Terminating immediately...")
        quit_forks
      end

      def term_forks
        signal_processes(forks.keys, :TERM)
      end

      def quit_forks
        signal_processes(forks.keys, :QUIT)
      end

      def stop_process_prune
        @prune_task&.shutdown
      end

      def delete_pidfile
        @pidfile&.delete
      end

      def prune_dead_processes
        wrap_in_app_executor do
          SolidQueue::Process.prune
        end
      end

      def start_fork(configured_process)
        configured_process.supervised_by process

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
        if supervised_fork = forks.delete(pid)
          SolidQueue.logger.info "[SolidQueue] Restarting fork[#{status.pid}] (status: #{status.exitstatus})"
          start_fork(supervised_fork)
        else
          SolidQueue.logger.info "[SolidQueue] Tried to replace fork[#{pid}] (status: #{status.exitstatus}, fork[#{status.pid}]), but it had already died  (status: #{status.exitstatus})"
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
