# frozen_string_literal: true

module SolidQueue
  class Supervisor
    include AppExecutor, Signals

    class << self
      def start(mode: :work, load_configuration_from: nil)
        configuration = Configuration.new(mode: mode, load_from: load_configuration_from)

        new(configuration.runners).start
      end
    end

    def initialize(runners)
      @runners = runners
      @forks = {}
    end

    def start
      setup_pidfile
      register_signal_handlers
      start_process_prune

      start_runners

      supervise
    rescue GracefulShutdownRequested
      graceful_shutdown
    rescue ImmediateShutdownRequested
      immediate_shutdown
    ensure
      stop_process_prune
      restore_default_signal_handlers
      delete_pidfile
    end

    private
      attr_reader :runners, :forks

      def setup_pidfile
        @pidfile = if SolidQueue.supervisor_pidfile
          Pidfile.new(SolidQueue.supervisor_pidfile).tap(&:setup)
        end
      end

      def start_process_prune
        @prune_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) { prune_dead_processes }
        @prune_task.execute
      end

      def start_runners
        runners.each { |runner| start_runner(runner) }
      end

      def supervise
        loop do
          process_signal_queue
          reap_and_replace_terminated_runners
          interruptible_sleep(1.second)
        end
      end

      def graceful_shutdown
        term_runners

        wait_until(SolidQueue.shutdown_timeout, -> { all_runners_terminated? }) do
          reap_terminated_runners
        end

        immediate_shutdown unless all_runners_terminated?
      end

      def immediate_shutdown
        quit_runners
      end

      def term_runners
        signal_processes(forks.keys, :TERM)
      end

      def quit_runners
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

      def start_runner(runner)
        runner.supervisor_pid = ::Process.pid

        pid = fork do
          runner.start
        end

        forks[pid] = runner
      end

      def reap_and_replace_terminated_runners
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          replace_runner(pid, status)
        end
      end

      def reap_terminated_runners
        loop do
          pid, status = ::Process.waitpid2(-1, ::Process::WNOHANG)
          break unless pid

          forks.delete(pid)
        end
      rescue SystemCallError
        # All children already reaped
      end

      def replace_runner(pid, status)
        if runner = forks.delete(pid)
          SolidQueue.logger.info "[SolidQueue] Restarting worker[#{status.pid}] (status: #{status.exitstatus})"
          start_runner(runner)
        else
          SolidQueue.logger.info "[SolidQueue] Tried to replace worker[#{pid}] (status: #{status.exitstatus}, runner[#{status.pid}]), but it had already died  (status: #{status.exitstatus})"
        end
      end

      def all_runners_terminated?
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
