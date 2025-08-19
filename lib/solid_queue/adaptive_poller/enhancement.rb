# frozen_string_literal: true

require_relative "../adaptive_poller"
require_relative "config"

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
  module AdaptivePoller::Enhancement
    extend ActiveSupport::Concern

    FALLBACK_INTERVAL = 10.minutes
    PERCENTAGE_CONVERSION_FACTOR = 100

    LOG_PRECISION_JOBS = 2
    LOG_PRECISION_PERCENTAGE = 1
    LOG_PRECISION_INTERVAL = 3
    LOG_PRECISION_ELAPSED = 0

    DEFAULT_POLLING_STATS = {
      total_polls: 0,
      total_jobs_claimed: 0,
      empty_polls: 0,
      last_reset: proc { Time.current }
    }.freeze

    included do
      attr_reader :adaptive_poller

      alias_method :original_initialize, :initialize

      def initialize(**options)
        original_initialize(**options)

        if SolidQueue.adaptive_polling_enabled?
          begin
            SolidQueue::AdaptivePoller::Config.validate!
          rescue SolidQueue::AdaptivePoller::Config::ConfigurationError => e
            SolidQueue.logger&.error "Adaptive Polling configuration error: #{e.message}"
            raise e
          end

          @adaptive_poller = AdaptivePoller.new(
            base_interval: polling_interval
          )
          @polling_stats = create_polling_stats

          config_summary = SolidQueue::AdaptivePoller::Config.configuration_summary
          SolidQueue.logger&.info "Worker #{process_id rescue 'unknown'} initialized with adaptive polling enabled: #{config_summary.inspect}"
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
        return unless @polling_stats.is_a?(Hash)

        @polling_stats[:total_polls] = (@polling_stats[:total_polls] || 0) + 1
        if jobs_claimed.zero?
          @polling_stats[:empty_polls] = (@polling_stats[:empty_polls] || 0) + 1
        else
          @polling_stats[:total_jobs_claimed] = (@polling_stats[:total_jobs_claimed] || 0) + jobs_claimed
        end
      end

      def should_log_stats?
        @polling_stats[:total_polls] % AdaptivePoller::STATS_LOG_INTERVAL == 0 ||
        (Time.current - @polling_stats[:last_reset]) > AdaptivePoller::STATS_RESET_INTERVAL
      end

      def log_polling_stats
        stats_summary = calculate_stats_summary
        log_stats_message(stats_summary)

        reset_polling_stats! if stats_summary[:elapsed] > AdaptivePoller::STATS_RESET_INTERVAL
      end

      def reset_polling_stats!
        @polling_stats = create_polling_stats
        adaptive_poller&.reset! if adaptive_poller.respond_to?(:reset!)
      end

      def create_polling_stats
        DEFAULT_POLLING_STATS.merge(last_reset: Time.current)
      end

      def calculate_stats_summary
        elapsed = Time.current - @polling_stats[:last_reset]
        avg_jobs_per_poll = @polling_stats[:total_jobs_claimed].to_f / @polling_stats[:total_polls]
        empty_poll_rate = @polling_stats[:empty_polls].to_f / @polling_stats[:total_polls]
        current_interval = adaptive_poller&.current_interval || polling_interval

        {
          elapsed: elapsed,
          avg_jobs_per_poll: avg_jobs_per_poll,
          empty_poll_rate: empty_poll_rate,
          current_interval: current_interval
        }
      end

      def log_stats_message(stats)
        SolidQueue.logger&.info(
          "Worker #{process_id} adaptive polling stats: " \
          "polls=#{@polling_stats[:total_polls]} " \
          "avg_jobs_per_poll=#{stats[:avg_jobs_per_poll].round(LOG_PRECISION_JOBS)} " \
          "empty_poll_rate=#{(stats[:empty_poll_rate] * PERCENTAGE_CONVERSION_FACTOR).round(LOG_PRECISION_PERCENTAGE)}% " \
          "current_interval=#{stats[:current_interval].round(LOG_PRECISION_INTERVAL)}s " \
          "elapsed=#{stats[:elapsed].round(LOG_PRECISION_ELAPSED)}s"
        )
      end
    end

    module ClassMethods
      def adaptive_polling_enabled?
        SolidQueue.adaptive_polling_enabled?
      end
    end
  end
end
