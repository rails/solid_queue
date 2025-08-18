# frozen_string_literal: true

module SolidQueue
  # Adaptive polling that adjusts interval based on workload
  # Reduces CPU and memory consumption when system is idle
  class AdaptivePoller
      def initialize(base_interval: 0.1)
    @base_interval = base_interval
    @current_interval = base_interval
    @last_interval = base_interval
    @stats_window = CircularBuffer.new(SolidQueue.adaptive_polling_window_size)
    @consecutive_empty_polls = 0
    @consecutive_busy_polls = 0
    @last_adjustment = Time.current
  end

    def next_interval(poll_result)
      record_poll_result(poll_result)
      calculate_adaptive_interval
    end

    def reset!
      @current_interval = @base_interval
      @stats_window.clear
      @consecutive_empty_polls = 0
      @consecutive_busy_polls = 0
    end

    def current_interval
      @current_interval
    end

  private

    attr_reader :base_interval, :stats_window

    def record_poll_result(result)
      job_count = extract_job_count(result)
      execution_time = extract_execution_time(result)

      stats_window.push({
        job_count: job_count,
        execution_time: execution_time,
        timestamp: Time.current,
        had_work: job_count > 0
      })

      update_consecutive_counters(job_count > 0)
    end

    def extract_job_count(result)
      case result
      when Integer
        result
      when Array
        result.size
      when Hash
        result[:job_count] || result[:size] || 0
      else
        result.respond_to?(:size) ? result.size : 0
      end
    end

    def extract_execution_time(result)
      case result
      when Hash
        result[:execution_time] || 0.001
      else
        0.001
      end
    end

    def update_consecutive_counters(had_work)
      if had_work
        @consecutive_busy_polls += 1
        @consecutive_empty_polls = 0
      else
        @consecutive_empty_polls += 1
        @consecutive_busy_polls = 0
      end
    end

    def calculate_adaptive_interval
      return @current_interval if should_skip_adjustment?

      new_interval = if system_is_busy?
        accelerate_polling
      elsif system_is_idle?
        decelerate_polling
      else
        maintain_current_interval
      end

      @current_interval = new_interval.clamp(SolidQueue.adaptive_polling_min_interval, SolidQueue.adaptive_polling_max_interval)
      @last_adjustment = Time.current

      log_interval_change if interval_changed?

      @current_interval
    end

    def should_skip_adjustment?
      # Don't adjust too frequently (but allow more frequent adjustments in tests)
      Time.current - @last_adjustment < 0.01
    end

    def system_is_busy?
      return false if stats_window.size < 3

      recent_work_rate = stats_window.recent(5).count { |stat| stat[:had_work] }.to_f / 5
      avg_job_count = stats_window.recent(5).sum { |stat| stat[:job_count] }.to_f / 5

      # System is busy if more than 60% of polls found work
      # OR if average jobs per poll > 2
      recent_work_rate > 0.6 || avg_job_count > 2
    end

    def system_is_idle?
      # System is idle if no work found in last 5 polls
      @consecutive_empty_polls >= 5
    end

    def accelerate_polling
      # Reduce interval when system is busy
      new_interval = @current_interval * SolidQueue.adaptive_polling_speedup_factor

      # Accelerate more rapidly if system is very busy
      if @consecutive_busy_polls >= 10
        new_interval *= 0.8
      end

      new_interval
    end

    def decelerate_polling
      # Increase interval when idle (exponential backoff)
      backoff_multiplier = [ 1 + (@consecutive_empty_polls * 0.1), 3.0 ].min
      @current_interval * SolidQueue.adaptive_polling_backoff_factor * backoff_multiplier
    end

    def maintain_current_interval
      # Gradually converge to base interval
      if @current_interval > base_interval
        [ @current_interval * 0.95, base_interval ].max
      elsif @current_interval < base_interval
        [ @current_interval * 1.05, base_interval ].min
      else
        @current_interval
      end
    end

    def interval_changed?
      (@current_interval - @last_interval).abs > 0.01
    end

    def log_interval_change
      @last_interval = @current_interval

      SolidQueue.logger&.debug(
        "Adaptive polling: interval adjusted to #{@current_interval.round(3)}s " \
        "(empty: #{@consecutive_empty_polls}, busy: #{@consecutive_busy_polls})"
      )
    end
  end

  # Circular buffer for polling statistics
  class CircularBuffer
    def initialize(size)
      @size = size
      @buffer = []
      @index = 0
    end

    def push(item)
      if @buffer.size < @size
        @buffer << item
      else
        @buffer[@index] = item
        @index = (@index + 1) % @size
      end
    end

    def recent(count = @size)
      return @buffer if @buffer.size <= count

      if @buffer.size < @size
        @buffer.last(count)
      else
        # Buffer full, get most recent considering circular index
        recent_items = []
        (0...count).each do |i|
          idx = (@index - 1 - i) % @size
          recent_items.unshift(@buffer[idx])
        end
        recent_items
      end
    end

    def size
      @buffer.size
    end

    def clear
      @buffer.clear
      @index = 0
    end
  end
end
