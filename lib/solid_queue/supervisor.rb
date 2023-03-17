# frozen_string_literal: true

class SolidQueue::Supervisor
  include SolidQueue::AppExecutor, SolidQueue::Runner

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

  attr_accessor :runners, :forks

  def initialize(runners)
    @runners = runners
    @forks = {}
  end

  def start
    trap_signals
    start_process_prune

    start_runners

    supervise

    stop_runners
    stop_process_prune
  end

  def stop
    @stopping = true
  end

  private
    def start_runners
      runners.each { |runner| start_runner(runner) }
    end

    def stop_runners
      signal_runners("TERM")
    end

    def start_process_prune
      @prune_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) { prune_dead_processes }
      @prune_task.execute
    end

    def stop_process_prune
      @prune_task.shutdown
    end

    def prune_dead_processes
      wrap_in_app_executor do
        SolidQueue::Process.prune
      end
    end

    def start_runner(runner)
      runner.supervisor_pid = process_pid

      pid = fork do
        Process.setpgrp
        runner.start
      end

      forks[pid] = runner
    end

    def signal_runners(signal)
      forks.keys.each do |pid|
        Process.kill signal, pid
      end
    end

    def supervise
      loop do
        break if stopping?
        detect_and_replace_terminated_runners

        sleep 0.1
      end
    end

    def detect_and_replace_terminated_runners
      loop do
        pid, status = Process.waitpid2(-1, Process::WNOHANG)
        break unless pid

        replace_runner(pid, status)
      end
    end

    def replace_runner(pid, status)
      if runner = forks.delete(pid)
        SolidQueue.logger.info "[SolidQueue] Restarting resque worker[#{status.pid}] (status: #{status.exitstatus}) #{runner.inspect}"
        start_runner(runner)
      else
        SolidQueue.logger.info "[SolidQueue] Tried to replace #{runner.inspect} (status: #{status.exitstatus}, runner[#{status.pid}]), but it had already died  (status: #{status.exitstatus})"
      end
    end
end
