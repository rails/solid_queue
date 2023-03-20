# frozen_string_literal: true

class SolidQueue::Supervisor
  include SolidQueue::AppExecutor

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

    @signal_queue = []

    # Self-pipe for deferred signal-handling (http://cr.yp.to/docs/selfpipe.html)
    @self_pipe = create_self_pipe
  end

  def start
    register_signal_handlers
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
    attr_reader :runners, :forks, :signal_queue

    SIGNALS = %i[ QUIT INT TERM ]

    def register_signal_handlers
      SIGNALS.each do |signal|
        trap(signal) do
          signal_queue << signal
          interrupt
        end
      end
    end

    def create_self_pipe
      reader, writer = IO.pipe
      { reader: reader, writer: writer }
    end

    def interrupt
      @self_pipe[:writer].write_nonblock( "." )
    rescue Errno::EAGAIN, Errno::EINTR
      # Ignore writes that would block and
      # retry if another signal arrived while writing
      retry
    end

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
      runner.supervisor_pid = Process.pid

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
        process_signal_queue
        break if stopping?

        detect_and_replace_terminated_runners

        interruptable_sleep(1.second)
      end
    end

    def process_signal_queue
      while signal = signal_queue.shift
        handle_signal(signal)
      end
    end

    def handle_signal(signal)
      case signal
      when :TERM, :INT
        stop
      when :QUIT
        quit
      else
        SolidQueue.logger.warn "Received unhandled signal #{signal}"
      end
    end

    def quit
      exit
    end

    CHUNK_SIZE = 11

    def interruptable_sleep(time)
      if @self_pipe[:reader].wait_readable(time)
        loop { @self_pipe[:reader].read_nonblock(CHUNK_SIZE) }
      end
    rescue Errno::EAGAIN, Errno::EINTR
    end

    def stopping?
      @stopping
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
