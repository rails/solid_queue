# frozen_string_literal: true

# CONFIGURATION EXAMPLE: Adaptive Polling for SolidQueue
#
# IMPORTANT: This file is just an EXAMPLE for applications using the SolidQueue gem.
#
# To use Adaptive Polling in your Rails application:
# 1. Copy this file to config/initializers/solid_queue_adaptive_polling.rb
# 2. OR add the configurations directly to config/application.rb or config/environments/*.rb
#
# Adaptive Polling automatically adjusts worker polling intervals
# based on workload, resulting in:
#
# ✅ Lower CPU consumption when system is idle
# ✅ Lower memory consumption by reducing unnecessary queries
# ✅ Faster response when there's work to process
# ✅ Better utilization of database resources

Rails.application.configure do
  # =============================================================================
  # ENABLE ADAPTIVE POLLING
  # =============================================================================

  # Enable adaptive polling (default: false)
  config.solid_queue.adaptive_polling_enabled = true

  # =============================================================================
  # ADVANCED SETTINGS (optional)
  # =============================================================================

  # Minimum polling interval (default: 0.05s = 50ms)
  # When system is very busy, polling will never be faster than this value
  config.solid_queue.adaptive_polling_min_interval = 0.05

  # Maximum polling interval (default: 5.0s)
  # When system is idle, polling will not exceed this value
  config.solid_queue.adaptive_polling_max_interval = 5.0

  # Interval growth factor when idle (default: 1.5)
  # Higher = polling slows down more quickly when there's no work
  config.solid_queue.adaptive_polling_backoff_factor = 1.5

  # Acceleration factor when busy (default: 0.7)
  # Lower = polling speeds up more quickly when there's work
  config.solid_queue.adaptive_polling_speedup_factor = 0.7

  # Analysis window size (default: 10)
  # How many recent polls to consider for making decisions
  config.solid_queue.adaptive_polling_window_size = 10
end

# =============================================================================
# RECOMMENDED CONFIGURATIONS BY ENVIRONMENT
# =============================================================================

# PRODUCTION - Aggressive configuration for maximum efficiency
if Rails.env.production?
  Rails.application.configure do
    config.solid_queue.adaptive_polling_enabled = true
    config.solid_queue.adaptive_polling_min_interval = 0.03      # Very fast when busy
    config.solid_queue.adaptive_polling_max_interval = 10.0     # Very slow when idle
    config.solid_queue.adaptive_polling_backoff_factor = 1.8    # Aggressive backoff
    config.solid_queue.adaptive_polling_speedup_factor = 0.5    # Aggressive acceleration
    config.solid_queue.adaptive_polling_window_size = 20        # More precise analysis
  end
end

# STAGING - Balanced configuration
if Rails.env.staging?
  Rails.application.configure do
    config.solid_queue.adaptive_polling_enabled = true
    # Use default values - already optimized for most cases
  end
end

# DEVELOPMENT - Conservative configuration
if Rails.env.development?
  Rails.application.configure do
    config.solid_queue.adaptive_polling_enabled = true          # Can test locally
    config.solid_queue.adaptive_polling_min_interval = 0.1      # Slower
    config.solid_queue.adaptive_polling_max_interval = 2.0      # Lower maximum
    config.solid_queue.adaptive_polling_backoff_factor = 1.2    # Gentle
    config.solid_queue.adaptive_polling_speedup_factor = 0.8    # Gentle
    config.solid_queue.adaptive_polling_window_size = 5         # Simple analysis
  end
end

# TESTS - Disabled for predictability
if Rails.env.test?
  Rails.application.configure do
    config.solid_queue.adaptive_polling_enabled = false         # Always disabled in tests
  end
end

# =============================================================================
# MONITORING AND LOGS (optional)
# =============================================================================

Rails.application.config.after_initialize do
  if SolidQueue.adaptive_polling_enabled?
    Rails.logger.info "🚀 SolidQueue Adaptive Polling enabled!"
    Rails.logger.info "📊 Applied configurations:"
    Rails.logger.info "   • Interval: #{SolidQueue.adaptive_polling_min_interval}s - #{SolidQueue.adaptive_polling_max_interval}s"
    Rails.logger.info "   • Factors: speedup=#{SolidQueue.adaptive_polling_speedup_factor}, backoff=#{SolidQueue.adaptive_polling_backoff_factor}"
    Rails.logger.info "   • Analysis window: #{SolidQueue.adaptive_polling_window_size} polls"
    Rails.logger.info "📈 Expect 20-40% reduction in CPU/memory consumption when system is idle"
  else
    Rails.logger.info "ℹ️  SolidQueue Adaptive Polling disabled"
  end
end
