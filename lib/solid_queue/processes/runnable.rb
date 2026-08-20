# frozen_string_literal: true

module SolidQueue::Processes
  module Runnable
    include Supervised

    def mode=(value)
      @mode = (value || DEFAULT_MODE).to_s.inquiry
    end

    def start
      run_in_mode do
        boot
        run
      end
    end

    def stop
      super
      wake_up

      # When not supervised, block until the thread terminates for backward
      # compatibility with code that expects stop to be synchronous.
      # When supervised, the supervisor controls the shutdown timeout.
      unless supervised?
        @thread&.join
      end
    end

    def alive?
      !running_async? || @thread&.alive?
    end

    def boot_timed_out?
      @boot_guard.timed_out?
    end

    def mark_as_reaped
      @boot_guard.close
    end

    private
      DEFAULT_MODE = :async

      def mode
        @mode ||= DEFAULT_MODE.to_s.inquiry
      end

      def run_in_mode(&block)
        case
        when running_as_fork?
          @boot_guard = BootGuards::ForkGuard.new
          create_fork(&block).tap { @boot_guard.start }
        when running_async?
          @boot_guard = BootGuards::NullGuard.new
          @thread = create_thread(&block)
          @thread.object_id
        else
          @boot_guard = BootGuards::NullGuard.new
          block.call
        end
      end

      def boot
        SolidQueue.instrument(:start_process, process: self) do
          run_callbacks(:boot) do
            set_procline if running_as_fork?
          end
        end

        @boot_guard.complete
      end

      def shutting_down?
        stopped? || (running_as_fork? && supervisor_went_away?) || finished? || !registered?
      end

      def run
        raise NotImplementedError
      end

      def finished?
        running_inline? && all_work_completed?
      end

      def all_work_completed?
        false
      end

      def shutdown
      end

      def set_procline
      end

      def running_inline?
        mode.inline?
      end

      def running_async?
        mode.async?
      end

      def running_as_fork?
        mode.fork?
      end
  end

  module BootGuards
    # Tracks a process that shares memory with its supervisor, whose boot time
    # doesn't need monitoring.
    class NullGuard
      def complete
        @completed = true
      end

      def start
      end

      def completed?
        @completed
      end

      def timed_out?
        false
      end

      def close
      end
    end

    # Tracks a forked process from the moment it's started until its boot
    # callbacks finish, over a pipe that survives forking: the forked process
    # writes to it when it's done booting, and its supervisor reads from it to
    # decide whether the process is taking too long to boot and needs replacing.
    class ForkGuard
      def initialize
        @reader, @writer = IO.pipe
        @created_at = SolidQueue::Timer.monotonic_time_now
      end

      # Runs in the forked process when it has finished booting
      def complete
        reader.close
        writer.write(".")
      rescue Errno::EPIPE
        # The supervisor stopped waiting while this process finished booting
      ensure
        writer.close
      end

      # Runs in the parent process right after forking
      def start
        writer.close
      end

      # A byte means boot completed; EOF means the process exited before
      # finishing its boot, and will be replaced when it's reaped
      def completed?
        @completed ||= begin
          completed = reader.read_nonblock(1, exception: false) != :wait_readable
          reader.close if completed
          completed
        end
      end

      def timed_out?
        !completed? && SolidQueue::Timer.monotonic_time_now - created_at >= SolidQueue.fork_boot_timeout
      end

      def close
        reader.close unless reader.closed?
        writer.close unless writer.closed?
      end

      private
        attr_reader :reader, :writer, :created_at
    end
  end
end
