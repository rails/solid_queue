# frozen_string_literal: true

module SolidQueue
  # Configuration validation for Adaptive Polling functionality.
  #
  # This module provides comprehensive validation of adaptive polling configuration
  # parameters to ensure they are valid and consistent before the system starts.
  # It helps prevent runtime errors and provides clear feedback about configuration issues.
  module AdaptivePoller::Config
    class ConfigurationError < StandardError; end

    class InvalidIntervalError < ConfigurationError; end
    class InvalidFactorError < ConfigurationError; end
    class InvalidWindowSizeError < ConfigurationError; end
    class InconsistentConfigurationError < ConfigurationError; end

    class << self
      def validate!
        return unless SolidQueue.adaptive_polling_enabled?

        validate_intervals!
        validate_factors!
        validate_window_size!
        validate_consistency!
      end

      def validate_intervals!
        min_interval = SolidQueue.adaptive_polling_min_interval
        max_interval = SolidQueue.adaptive_polling_max_interval

        unless positive_numeric?(min_interval)
          raise InvalidIntervalError,
            "adaptive_polling_min_interval must be a positive number, got: #{min_interval.inspect}"
        end

        unless positive_numeric?(max_interval)
          raise InvalidIntervalError,
            "adaptive_polling_max_interval must be a positive number, got: #{max_interval.inspect}"
        end

        if min_interval >= max_interval
          raise InconsistentConfigurationError,
            "adaptive_polling_min_interval (#{min_interval}) must be less than " \
            "adaptive_polling_max_interval (#{max_interval})"
        end

        if min_interval < 0.001
          raise InvalidIntervalError,
            "adaptive_polling_min_interval (#{min_interval}) is too small. " \
            "Minimum recommended value is 0.001 (1ms)"
        end

        if max_interval > 300
          raise InvalidIntervalError,
            "adaptive_polling_max_interval (#{max_interval}) is too large. " \
            "Maximum recommended value is 300 (5 minutes)"
        end
      end

      def validate_factors!
        backoff_factor = SolidQueue.adaptive_polling_backoff_factor
        speedup_factor = SolidQueue.adaptive_polling_speedup_factor

        unless positive_numeric?(backoff_factor)
          raise InvalidFactorError,
            "adaptive_polling_backoff_factor must be a positive number, got: #{backoff_factor.inspect}"
        end

        unless positive_numeric?(speedup_factor)
          raise InvalidFactorError,
            "adaptive_polling_speedup_factor must be a positive number, got: #{speedup_factor.inspect}"
        end

        if backoff_factor <= 1.0
          raise InvalidFactorError,
            "adaptive_polling_backoff_factor (#{backoff_factor}) must be greater than 1.0 " \
            "to slow down polling when idle"
        end

        if speedup_factor >= 1.0
          raise InvalidFactorError,
            "adaptive_polling_speedup_factor (#{speedup_factor}) must be less than 1.0 " \
            "to speed up polling when busy"
        end

        if backoff_factor > 5.0
          raise InvalidFactorError,
            "adaptive_polling_backoff_factor (#{backoff_factor}) is too large. " \
            "Values above 5.0 may cause excessive delays"
        end

        if speedup_factor < 0.1
          raise InvalidFactorError,
            "adaptive_polling_speedup_factor (#{speedup_factor}) is too small. " \
            "Values below 0.1 may cause excessive CPU usage"
        end
      end

      def validate_window_size!
        window_size = SolidQueue.adaptive_polling_window_size

        unless positive_integer?(window_size)
          raise InvalidWindowSizeError,
            "adaptive_polling_window_size must be a positive integer, got: #{window_size.inspect}"
        end

        if window_size < 3
          raise InvalidWindowSizeError,
            "adaptive_polling_window_size (#{window_size}) is too small. " \
            "Minimum value is 3 for meaningful analysis"
        end

        if window_size > 1000
          raise InvalidWindowSizeError,
            "adaptive_polling_window_size (#{window_size}) is too large. " \
            "Values above 1000 may consume excessive memory"
        end
      end

      def validate_consistency!
        min_interval = SolidQueue.adaptive_polling_min_interval
        max_interval = SolidQueue.adaptive_polling_max_interval
        backoff_factor = SolidQueue.adaptive_polling_backoff_factor

        ratio = max_interval / min_interval
        if ratio < 2.0
          raise InconsistentConfigurationError,
            "The ratio between max_interval (#{max_interval}) and min_interval (#{min_interval}) " \
            "is too small (#{ratio.round(2)}). A ratio of at least 2.0 is recommended for " \
            "effective adaptive behavior"
        end

        if ratio > 1000
          raise InconsistentConfigurationError,
            "The ratio between max_interval (#{max_interval}) and min_interval (#{min_interval}) " \
            "is very large (#{ratio.round(2)}). This may cause unpredictable behavior. " \
            "Consider using a ratio below 1000"
        end
      end

      def configuration_summary
        return "Adaptive Polling: DISABLED" unless SolidQueue.adaptive_polling_enabled?

        {
          enabled: true,
          min_interval: "#{SolidQueue.adaptive_polling_min_interval}s",
          max_interval: "#{SolidQueue.adaptive_polling_max_interval}s",
          backoff_factor: SolidQueue.adaptive_polling_backoff_factor,
          speedup_factor: SolidQueue.adaptive_polling_speedup_factor,
          window_size: SolidQueue.adaptive_polling_window_size,
          interval_ratio: (SolidQueue.adaptive_polling_max_interval / SolidQueue.adaptive_polling_min_interval).round(2)
        }
      end

      private

      def positive_numeric?(value)
        value.is_a?(Numeric) && value > 0
      end

      def positive_integer?(value)
        value.is_a?(Integer) && value > 0
      end
    end
  end
end
