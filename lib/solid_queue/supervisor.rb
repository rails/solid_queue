# frozen_string_literal: true

module SolidQueue
  class Supervisor
    include AppExecutor, Signals

    class << self
      def start(mode: :work, configuration: SolidQueue::Configuration.new)
        runners = case mode
        when :schedule then scheduler(configuration)
        when :work     then workers(configuration)
        when :all      then [ scheduler(configuration) ] + workers(configuration)
        else           raise "Invalid mode #{mode}"
        end

        new(runners).start
      end

      def workers(configuration)
        configuration.queues.values.map { |queue_options| SolidQueue::Worker.new(**queue_options) }
      end

      def scheduler(configuration)
        SolidQueue::Scheduler.new(**configuration.scheduler_options)
      end
    end

    def initialize(runners)
      @runners = runners
      @forks = {}
    end

    def start
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
    end

    private
      attr_reader :runners, :forks

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
          break if stopping?

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
        @prune_task.shutdown
      end

      def stop
        @stopping = true
      end

      def prune_dead_processes
        wrap_in_app_executor do
          SolidQueue::Process.prune
        end
      end

      def start_runner(runner)
        runner.supervisor_pid = ::Process.pid

        pid = fork do
          ::Process.setpgrp
          runner.start
        end

        forks[pid] = runner
      end

      def stopping?
        @stopping
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
          SolidQueue.logger.info "[SolidQueue] Restarting resque worker[#{status.pid}] (status: #{status.exitstatus}) #{runner.inspect}"
          start_runner(runner)
        else
          SolidQueue.logger.info "[SolidQueue] Tried to replace #{runner.inspect} (status: #{status.exitstatus}, runner[#{status.pid}]), but it had already died  (status: #{status.exitstatus})"
        end
      end

      def all_runners_terminated?
        forks.empty?
      end

      def wait_until(timeout, condition, &block)
        if timeout > 0
          now = monotonic_time_now
          deadline = now + timeout
          while now < deadline && !condition.call
            sleep 0.1
            block.call
            now = monotonic_time_now
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
