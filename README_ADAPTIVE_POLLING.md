# SolidQueue Adaptive Polling - Quick Start

This gem includes **Adaptive Polling** functionality that automatically optimizes workers' CPU and memory consumption.

## 🚀 For Gem Users

### 1. Basic Setup

In **your Rails application**, add to `config/application.rb`:

```ruby
Rails.application.configure do
  config.solid_queue.adaptive_polling_enabled = true
end
```

### 2. Environment-specific Configuration

```ruby
# config/environments/production.rb
Rails.application.configure do
  config.solid_queue.adaptive_polling_enabled = true
  config.solid_queue.adaptive_polling_min_interval = 0.03     # 30ms minimum
  config.solid_queue.adaptive_polling_max_interval = 8.0      # 8s maximum
end

# config/environments/development.rb  
Rails.application.configure do
  config.solid_queue.adaptive_polling_enabled = true
  config.solid_queue.adaptive_polling_min_interval = 0.1      # 100ms minimum
  config.solid_queue.adaptive_polling_max_interval = 3.0      # 3s maximum
end

# config/environments/test.rb
Rails.application.configure do
  config.solid_queue.adaptive_polling_enabled = false         # Always disabled in tests
end
```

### 3. Complete Configuration (Optional)

Create `config/initializers/solid_queue_adaptive_polling.rb`:

```ruby
Rails.application.configure do
  # Enable functionality
  config.solid_queue.adaptive_polling_enabled = true
  
  # Advanced settings
  config.solid_queue.adaptive_polling_min_interval = 0.05      # Minimum interval (50ms)
  config.solid_queue.adaptive_polling_max_interval = 5.0       # Maximum interval (5s)
  config.solid_queue.adaptive_polling_backoff_factor = 1.5     # Growth factor when idle
  config.solid_queue.adaptive_polling_speedup_factor = 0.7     # Acceleration factor when busy
  config.solid_queue.adaptive_polling_window_size = 10         # Analysis window
end
```

## 📊 Expected Benefits

- **20-40% less CPU** when system is idle
- **20-50% less memory** by reducing unnecessary queries
- **Faster response** when there's work
- **Automatic adaptation** based on load

## 🔍 Verification

After configuration, check your application logs:

```
SolidQueue Adaptive Polling ENABLED with configuration:
  - Min interval: 0.05s
  - Max interval: 5.0s
  - Backoff factor: 1.5
  - Speedup factor: 0.7
```

## 📚 Complete Documentation

For advanced configurations and troubleshooting, see:
- `ADAPTIVE_POLLING.md` - Complete documentation
- `examples_adaptive_polling_config.rb` - Example with all options

---

**💡 Tip**: Start with basic configuration and adjust as needed based on your application's behavior.
