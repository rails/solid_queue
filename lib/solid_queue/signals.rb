# frozen_string_literal: true

module SolidQueue
  module Signals
    private

    SIGNALS = %i[ QUIT INT TERM ]
    SELF_PIPE_BLOCK_SIZE = 11

    def register_signal_handlers
      SIGNALS.each do |signal|
        trap(signal) do
          signal_queue << signal
          interrupt
        end
      end
    end

    def restore_default_signal_handlers
      SIGNALS.each do |signal|
        trap(signal, :DEFAULT)
      end
    end

    def interrupt
      self_pipe[:writer].write_nonblock( "." )
    rescue Errno::EAGAIN, Errno::EINTR
      # Ignore writes that would block and
      # retry if another signal arrived while writing
      retry
    end

    def process_signal_queue
      while signal = signal_queue.shift
        handle_signal(signal)
      end
    end

    def handle_signal(signal)
      case signal
      when :TERM, :INT
        graceful_shutdown
      when :QUIT
        immediate_shutdown
      else
        SolidQueue.logger.warn "Received unhandled signal #{signal}"
      end
    end

    def graceful_shutdown
      stop
    end

    def immediate_shutdown
      exit
    end

    def interruptible_sleep(time)
      if self_pipe[:reader].wait_readable(time)
        loop { self_pipe[:reader].read_nonblock(SELF_PIPE_BLOCK_SIZE) }
      end
    rescue Errno::EAGAIN, Errno::EINTR
    end

    def signal_processes(pids, signal)
      pids.each do |pid|
        ::Process.kill signal, pid
      end
    end


    def signal_queue
      @signal_queue ||= []
    end

    # Self-pipe for deferred signal-handling (http://cr.yp.to/docs/selfpipe.html)
    def self_pipe
      @self_pipe ||= create_self_pipe
    end

    def create_self_pipe
      reader, writer = IO.pipe
      { reader: reader, writer: writer }
    end
  end
end
