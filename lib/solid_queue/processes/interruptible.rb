# frozen_string_literal: true

module SolidQueue::Processes
  module Interruptible
    def wake_up
      interrupt
    end

    private
      SELF_PIPE_BLOCK_SIZE = 11

      def interrupt
        self_pipe[:writer].write_nonblock(".")
      rescue Errno::EAGAIN, Errno::EINTR
        # Ignore writes that would block and retry
        # if another signal arrived while writing
        retry
      end

      def interruptible_sleep(time)
        if time > 0 && self_pipe[:reader].wait_readable(time)
          loop { self_pipe[:reader].read_nonblock(SELF_PIPE_BLOCK_SIZE) }
        end
      rescue Errno::EAGAIN, Errno::EINTR
      end

      # Self-pipe for signal-handling (http://cr.yp.to/docs/selfpipe.html)
      def self_pipe
        @self_pipe ||= create_self_pipe
      end

      def create_self_pipe
        reader, writer = IO.pipe
        { reader: reader, writer: writer }
      end
  end
end
