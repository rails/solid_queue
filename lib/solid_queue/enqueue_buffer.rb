# frozen_string_literal: true

module SolidQueue
  # Holds jobs in memory while the queue database can't be reached, and enqueues
  # them once it's back, instead of raising and losing them. Opt-in with
  # +SolidQueue.buffer_enqueues_on_database_error+.
  #
  # The buffer lives in the enqueuing process: jobs held when that process
  # crashes are lost. A normal exit tries once more to enqueue what's left.
  module EnqueueBuffer
    extend self
    extend AppExecutor

    CONNECTION_ERRORS = [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed ].freeze
    MIN_RETRY_INTERVAL = 1.second
    MAX_RETRY_INTERVAL = 30.seconds

    # Held jobs belong to the process that held them. A forked child starts
    # empty, so it can't enqueue its parent's jobs a second time, and gets its
    # own flusher, since threads don't survive a fork.
    def reset
      @jobs = []
      @mutex = Mutex.new
      @flusher = nil
    end

    reset
    ActiveSupport::ForkTracker.after_fork { reset }

    # Holds +active_jobs+ when +error+ means the database can't be reached,
    # buffering is enabled and the buffer has room for all of them. Held jobs
    # count as enqueued.
    def hold(active_jobs, error)
      return false unless holdable?(error)

      held = mutex.synchronize do
        if jobs.size + active_jobs.size <= SolidQueue.enqueue_buffer_size
          jobs.concat(active_jobs)
          start_flushing
          true
        end
      end

      SolidQueue.instrument(:buffer_enqueue, size: active_jobs.size, held: !!held, error: error)
      active_jobs.each { |job| job.successfully_enqueued = true } if held

      !!held
    end

    # Tries to enqueue every held job. Returns false when the database still
    # can't be reached, putting the jobs back to try again later.
    def flush
      batch = mutex.synchronize { jobs.shift(jobs.size) }
      return true if batch.empty?

      SolidQueue.instrument(:flush_enqueue_buffer, size: batch.size) do
        flushing { wrap_in_app_executor { Job.enqueue_all(batch) } }
      end
      true
    rescue *CONNECTION_ERRORS
      mutex.synchronize { jobs.unshift(*batch) }
      false
    rescue StandardError => error
      # Anything but an unreachable database won't fix itself by retrying:
      # report it, as other Solid Queue thread errors are, and drop the batch.
      handle_thread_error(error)
      true
    end

    def size
      mutex.synchronize { jobs.size }
    end

    private
      def holdable?(error)
        SolidQueue.buffer_enqueues_on_database_error &&
          CONNECTION_ERRORS.any? { |error_class| error.is_a?(error_class) } &&
          !Thread.current[:solid_queue_flushing_enqueue_buffer]
      end

      def flushing
        Thread.current[:solid_queue_flushing_enqueue_buffer] = true
        yield
      ensure
        Thread.current[:solid_queue_flushing_enqueue_buffer] = false
      end

      # Called with the mutex held.
      def start_flushing
        @flusher ||= create_thread { flush_until_empty }
        @exit_hook ||= at_exit { flush_on_exit }
      end

      def flush_until_empty
        interval = MIN_RETRY_INTERVAL

        loop do
          sleep interval
          interval = flush ? MIN_RETRY_INTERVAL : [ interval * 2, MAX_RETRY_INTERVAL ].min
          break if stop_flushing_if_empty
        end
      end

      def flush_on_exit
        SolidQueue.instrument(:lose_held_jobs, size: size) unless flush
      end

      # Decided under the mutex, so a job held right after the check starts a
      # new flusher instead of waiting for one that is about to exit.
      def stop_flushing_if_empty
        mutex.synchronize do
          @flusher = nil if jobs.empty?
          @flusher.nil?
        end
      end

      attr_reader :jobs, :mutex
  end
end
