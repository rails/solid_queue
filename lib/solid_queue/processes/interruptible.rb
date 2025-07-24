# frozen_string_literal: true

module SolidQueue::Processes
  module Interruptible
    def initialize(...)
      super
      @self_pipe = create_self_pipe
    end

    def wake_up
      interrupt
    end

    private
      SELF_PIPE_BLOCK_SIZE = 11

      attr_reader :self_pipe

      def interrupt
        self_pipe[:writer].write_nonblock(".")
      rescue Errno::EAGAIN, Errno::EINTR
        # Ignore writes that would block and retry
        # if another signal arrived while writing
        retry
      end

      def interruptible_sleep(time)
        # Supervisor Lifecycle - 11.1
        # Wait for the self-pipe to be readable, which indicates an interrupt
        # If the time is 0, it will return immediately if the pipe is readable
        # If the time is greater than 0, it will wait for the specified time
        # If the pipe is readable, it will read all data from the pipe
        # to clear it and avoid blocking on future reads.
        if time > 0 && self_pipe[:reader].wait_readable(time)
          loop { self_pipe[:reader].read_nonblock(SELF_PIPE_BLOCK_SIZE) }
        end
      rescue Errno::EAGAIN, Errno::EINTR, IO::EWOULDBLOCKWaitReadable
      end

      # Self-pipe for signal-handling (http://cr.yp.to/docs/selfpipe.html)
      def create_self_pipe
        reader, writer = IO.pipe
        { reader: reader, writer: writer }
      end
  end
end
