# frozen_string_literal: true

require_relative "adaptive_poller"

module SolidQueue
  # Enhancement module that adds adaptive polling capabilities to SolidQueue workers.
  #
  # This module extends existing Worker instances to include adaptive polling logic
  # without modifying the core Worker class directly. It provides:
  # - Dynamic polling interval adjustment based on workload
  # - Statistical tracking and logging of polling performance
  # - Graceful fallback to original polling behavior when disabled
  #
  # The enhancement is applied through method aliasing and can be safely
  # enabled/disabled via configuration flags.
  module AdaptivePollingEnhancement
    extend ActiveSupport::Concern

    FALLBACK_INTERVAL = 10.minutes

    PERCENTAGE_CONVERSION_FACTOR = 100

    included do
      attr_reader :adaptive_poller

      alias_method :original_initialize, :initialize

      def initialize(**options)
        original_initialize(**options)

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

      alias_method :original_poll, :poll

      def poll
        start_time = Time.current

        executions = claim_executions
        execution_time = Time.current - start_time

        executions.each do |execution|
          pool.post(execution)
        end

        update_polling_stats(executions.size) if adaptive_poller

        if adaptive_poller
          poll_result = {
            job_count: executions.size,
            execution_time: execution_time,
            pool_idle: pool.idle?
          }

          next_interval = adaptive_poller.next_interval(poll_result)

          log_polling_stats if should_log_stats?

          next_interval
        else
          pool.idle? ? polling_interval : FALLBACK_INTERVAL
        end
      end

      private

      def update_polling_stats(jobs_claimed)
        @polling_stats[:total_polls] += 1
        jobs_claimed.zero? ? @polling_stats[:empty_polls] += 1 : @polling_stats[:total_jobs_claimed] += jobs_claimed
      end

      def should_log_stats?
        @polling_stats[:total_polls] % AdaptivePoller::STATS_LOG_INTERVAL == 0 ||
        (Time.current - @polling_stats[:last_reset]) > AdaptivePoller::STATS_RESET_INTERVAL
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
          "empty_poll_rate=#{(empty_poll_rate * PERCENTAGE_CONVERSION_FACTOR).round(1)}% " \
          "current_interval=#{current_interval.round(3)}s " \
          "elapsed=#{elapsed.round(0)}s"
        )

        if elapsed > AdaptivePoller::STATS_RESET_INTERVAL
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

    module ClassMethods
      def adaptive_polling_enabled?
        SolidQueue.adaptive_polling_enabled?
      end
    end
  end
end
