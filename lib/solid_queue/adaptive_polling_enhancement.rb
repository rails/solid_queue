# frozen_string_literal: true

require_relative "adaptive_poller"

module SolidQueue
  # Enhancement to add adaptive polling to existing workers
  module AdaptivePollingEnhancement
    extend ActiveSupport::Concern

    included do
      attr_reader :adaptive_poller

      # Override initialization to include adaptive poller
      alias_method :original_initialize, :initialize

      def initialize(**options)
        original_initialize(**options)

        # Initialize adaptive poller if enabled in SolidQueue settings
        if SolidQueue.adaptive_polling_enabled?
          @adaptive_poller = AdaptivePoller.new(
            base_interval: polling_interval
          )
          @polling_stats = {
            total_polls: 0,
            total_jobs_claimed: 0,
            empty_polls: 0,
            last_reset: Time.current
          }

          SolidQueue.logger&.info "Worker #{process_id rescue 'unknown'} initialized with adaptive polling enabled"
        end
      end

      # Override poll method to use adaptive polling
      alias_method :original_poll, :poll

      def poll
        start_time = Time.current

        executions = claim_executions
        execution_time = Time.current - start_time

        # Process executions
        executions.each do |execution|
          pool.post(execution)
        end

        # Update statistics
        update_polling_stats(executions.size) if adaptive_poller

        # Calculate next interval
        if adaptive_poller
          poll_result = {
            job_count: executions.size,
            execution_time: execution_time,
            pool_idle: pool.idle?
          }

          next_interval = adaptive_poller.next_interval(poll_result)

          # Periodic statistics logging
          log_polling_stats if should_log_stats?

          next_interval
        else
          # Fallback to original behavior
          pool.idle? ? polling_interval : 10.minutes
        end
      end

      private

      def update_polling_stats(jobs_claimed)
        @polling_stats[:total_polls] += 1
        @polling_stats[:total_jobs_claimed] += jobs_claimed
        @polling_stats[:empty_polls] += 1 if jobs_claimed == 0
      end

      def should_log_stats?
        # Log every 1000 polls or 5 minutes
        @polling_stats[:total_polls] % 1000 == 0 ||
        (Time.current - @polling_stats[:last_reset]) > 300
      end

      def log_polling_stats
        elapsed = Time.current - @polling_stats[:last_reset]
        avg_jobs_per_poll = @polling_stats[:total_jobs_claimed].to_f / @polling_stats[:total_polls]
        empty_poll_rate = @polling_stats[:empty_polls].to_f / @polling_stats[:total_polls]
        current_interval = adaptive_poller&.current_interval || polling_interval

        SolidQueue.logger&.info(
          "Worker #{process_id} adaptive polling stats: " \
          "polls=#{@polling_stats[:total_polls]} " \
          "avg_jobs_per_poll=#{avg_jobs_per_poll.round(2)} " \
          "empty_poll_rate=#{(empty_poll_rate * 100).round(1)}% " \
          "current_interval=#{current_interval.round(3)}s " \
          "elapsed=#{elapsed.round(0)}s"
        )

        # Reset stats periodically
        if elapsed > 300
          reset_polling_stats!
        end
      end

      def reset_polling_stats!
        @polling_stats = {
          total_polls: 0,
          total_jobs_claimed: 0,
          empty_polls: 0,
          last_reset: Time.current
        }
        adaptive_poller&.reset! if adaptive_poller.respond_to?(:reset!)
      end
    end

    # Class methods for configuration
    module ClassMethods
      def adaptive_polling_enabled?
        SolidQueue.adaptive_polling_enabled?
      end
    end
  end
end
