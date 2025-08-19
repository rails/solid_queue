# frozen_string_literal: true

module SolidQueue
  # Adaptive polling that dynamically adjusts polling intervals based on system workload.
  #
  # This class monitors job queue activity and adjusts polling frequency to:
  # - Reduce CPU and memory consumption when the system is idle
  # - Increase responsiveness when the system is busy processing many jobs
  # - Maintain optimal balance between resource usage and job processing latency
  #
  # The algorithm uses statistical analysis of recent polling results to determine
  # whether the system should poll more or less frequently.
  class AdaptivePoller
    MIN_ADJUSTMENT_INTERVAL = 0.01
    BUSY_WORK_RATE_THRESHOLD = 0.6
    BUSY_AVG_JOBS_THRESHOLD = 2
    IDLE_CONSECUTIVE_POLLS = 5
    RAPID_ACCELERATION_THRESHOLD = 10
    MAX_BACKOFF_MULTIPLIER = 3.0
    CONVERGENCE_FACTOR = 0.95
    REVERSE_CONVERGENCE_FACTOR = 1.05
    RAPID_ACCELERATION_FACTOR = 0.8
    INTERVAL_CHANGE_THRESHOLD = 0.01
    STATS_LOG_INTERVAL = 1000
    STATS_RESET_INTERVAL = 300

    attr_reader :base_interval, :current_interval

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

  private

    attr_reader :stats_window

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
        [ result, 0 ].max
      when Array
        result.size
      when Hash
        count = result[:job_count] || result[:size] || 0
        count.is_a?(Integer) ? [ count, 0 ].max : 0
      else
        result.respond_to?(:size) ? [ result.size, 0 ].max : 0
      end
    end

    def extract_execution_time(result)
      case result
      when Hash
        time = result[:execution_time]
        time.is_a?(Numeric) && time > 0 ? time : 0.001
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
      Time.current - @last_adjustment < MIN_ADJUSTMENT_INTERVAL
    end

    def system_is_busy?
      return false if stats_window.size < 3

      recent_work_rate = stats_window.recent(IDLE_CONSECUTIVE_POLLS).count { |stat| stat[:had_work] }.to_f / IDLE_CONSECUTIVE_POLLS
      avg_job_count = stats_window.recent(IDLE_CONSECUTIVE_POLLS).sum { |stat| stat[:job_count] }.to_f / IDLE_CONSECUTIVE_POLLS

      recent_work_rate > BUSY_WORK_RATE_THRESHOLD || avg_job_count > BUSY_AVG_JOBS_THRESHOLD
    end

    def system_is_idle?
      @consecutive_empty_polls >= IDLE_CONSECUTIVE_POLLS
    end

    def accelerate_polling
      new_interval = @current_interval * SolidQueue.adaptive_polling_speedup_factor

      if @consecutive_busy_polls >= RAPID_ACCELERATION_THRESHOLD
        new_interval *= RAPID_ACCELERATION_FACTOR
      end

      new_interval
    end

    def decelerate_polling
      backoff_multiplier = [ 1 + (@consecutive_empty_polls * 0.1), MAX_BACKOFF_MULTIPLIER ].min
      @current_interval * SolidQueue.adaptive_polling_backoff_factor * backoff_multiplier
    end

    def maintain_current_interval
      if @current_interval > base_interval
        [ @current_interval * CONVERGENCE_FACTOR, base_interval ].max
      elsif @current_interval < base_interval
        [ @current_interval * REVERSE_CONVERGENCE_FACTOR, base_interval ].min
      else
        @current_interval
      end
    end

    def interval_changed?
      (@current_interval - @last_interval).abs > INTERVAL_CHANGE_THRESHOLD
    end

    def log_interval_change
      @last_interval = @current_interval

      SolidQueue.logger&.debug(
        "Adaptive polling: interval adjusted to #{@current_interval.round(3)}s " \
        "(empty: #{@consecutive_empty_polls}, busy: #{@consecutive_busy_polls})"
      )
    end
  end

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
