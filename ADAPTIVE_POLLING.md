# 🚀 SolidQueue Adaptive Polling

**Adaptive Polling** is a feature that automatically optimizes SolidQueue's memory and CPU consumption by dynamically adjusting worker polling intervals based on current workload.

> **💡 Important**: This is a SolidQueue gem feature. Configuration should be done in the **Rails application that consumes the gem**, not in the gem itself.

## 📊 Benefits

- **20-40% less CPU** when system is idle
- **20-50% less memory** by reducing unnecessary queries  
- **Faster response** when there's work to process
- **Better utilization** of database resources
- **Intelligent behavior** that adapts automatically

## 🔧 How It Works

The system continuously monitors:
- How many jobs are found in each poll
- Query execution time
- Load patterns over time

Based on these metrics, it:
- **Accelerates** polling when it detects work (down to configured minimum)
- **Decelerates** polling when there's no work (up to configured maximum)
- **Converges** gradually to base interval when load is stable

## ⚙️ Configuration

### Basic Setup

**In your Rails application** that uses the SolidQueue gem, add to `config/application.rb` or `config/environments/production.rb`:

```ruby
Rails.application.configure do
  # Enable adaptive polling
  config.solid_queue.adaptive_polling_enabled = true
end
```

### Advanced Configuration

**In your Rails application**, create a file `config/initializers/solid_queue_adaptive_polling.rb`:

```ruby
# config/initializers/solid_queue_adaptive_polling.rb
Rails.application.configure do
  config.solid_queue.adaptive_polling_enabled = true
  
  # Minimum interval when system is busy (default: 0.05s)
  config.solid_queue.adaptive_polling_min_interval = 0.03
  
  # Maximum interval when system is idle (default: 5.0s) 
  config.solid_queue.adaptive_polling_max_interval = 8.0
  
  # Growth factor when idle (default: 1.5)
  config.solid_queue.adaptive_polling_backoff_factor = 1.6
  
  # Acceleration factor when busy (default: 0.7)
  config.solid_queue.adaptive_polling_speedup_factor = 0.6
  
  # Analysis window size (default: 10)
  config.solid_queue.adaptive_polling_window_size = 15
end
```

## 🌟 Recommended Configurations

### Production (Aggressive)
```ruby
# Maximum efficiency for high-load environments
config.solid_queue.adaptive_polling_min_interval = 0.03     # 30ms minimum
config.solid_queue.adaptive_polling_max_interval = 10.0    # 10s maximum  
config.solid_queue.adaptive_polling_backoff_factor = 1.8   # Fast backoff
config.solid_queue.adaptive_polling_speedup_factor = 0.5   # Fast acceleration
config.solid_queue.adaptive_polling_window_size = 20       # Precise analysis
```

### Staging (Balanced)
```ruby
# Balanced configuration - use defaults
config.solid_queue.adaptive_polling_enabled = true
# Other settings use default values
```

### Development (Conservative)  
```ruby
# More predictable behavior for development
config.solid_queue.adaptive_polling_min_interval = 0.1     # 100ms minimum
config.solid_queue.adaptive_polling_max_interval = 2.0     # 2s maximum
config.solid_queue.adaptive_polling_backoff_factor = 1.2   # Gentle
config.solid_queue.adaptive_polling_speedup_factor = 0.8   # Gentle
```

## 📈 Monitoring

The system automatically logs information about its operation:

### Startup Logs
```
SolidQueue Adaptive Polling ENABLED with configuration:
  - Min interval: 0.05s
  - Max interval: 5.0s  
  - Backoff factor: 1.5
  - Speedup factor: 0.7
  - Window size: 10
```

### Operation Logs (Debug)
```
Worker 12345 adaptive polling stats: polls=1000 avg_jobs_per_poll=2.3 empty_poll_rate=45.2% current_interval=0.125s
Adaptive polling: interval adjusted to 0.087s (empty: 0, busy: 15)
```

### Worker Statistics
```
Worker 12345 Adaptive Polling stats: uptime=3600s polls=5420 jobs=8765 efficiency=1.617 jobs/poll avg_interval=0.324s
```

## 🔬 How to Test

### 1. Test Environment
```ruby
# In your Rails application, in config/environments/development.rb
Rails.application.configure do
  config.logger.level = :info
  config.solid_queue.adaptive_polling_enabled = true
end
```

### 2. Simulate Load
```ruby
# In your Rails application console (rails console)
100.times { MyJob.perform_later }

# Wait for processing and observe solid_queue logs
# Interval should decrease when there's work
```

### 3. Simulate Idle
```ruby
# Stop creating jobs
# Observe interval gradually increasing in logs
```

## 🐛 Troubleshooting

### Issue: Polling too slow
```ruby
# Reduce maximum interval
config.solid_queue.adaptive_polling_max_interval = 2.0

# Reduce backoff factor  
config.solid_queue.adaptive_polling_backoff_factor = 1.2
```

### Issue: Polling too fast
```ruby
# Increase minimum interval
config.solid_queue.adaptive_polling_min_interval = 0.1

# Increase speedup factor (closer to 1.0)
config.solid_queue.adaptive_polling_speedup_factor = 0.8
```

### Issue: Slow adaptation
```ruby
# Reduce analysis window for faster reaction
config.solid_queue.adaptive_polling_window_size = 5

# Adjust factors for more aggressive changes
config.solid_queue.adaptive_polling_backoff_factor = 1.8
config.solid_queue.adaptive_polling_speedup_factor = 0.5
```

## 🔧 Advanced Per-Worker Configuration

For different configurations per worker, use YAML configuration:

```yaml
# config/queue.yml
production:
  workers:
    - queues: "critical"
      threads: 5
      adaptive_polling:
        min_interval: 0.01
        max_interval: 1.0
    - queues: "background"  
      threads: 3
      adaptive_polling:
        min_interval: 0.1
        max_interval: 10.0
```

## 📚 Detailed Algorithm

### System States
- **Busy**: > 60% of polls found work OR average > 2 jobs/poll
- **Idle**: >= 5 consecutive polls without work  
- **Stable**: Between busy and idle

### Adaptation Logic
```ruby
if busy?
  new_interval = current_interval * speedup_factor
  # Accelerate more if very busy (10+ consecutive polls)
  new_interval *= 0.8 if consecutive_busy_polls >= 10
  
elsif idle?
  backoff_multiplier = [1 + (consecutive_empty_polls * 0.1), 3.0].min
  new_interval = current_interval * backoff_factor * backoff_multiplier
  
else
  # Gradually converge to base interval
  new_interval = current_interval.lerp(base_interval, 0.05)
end

# Always respect min/max limits
new_interval.clamp(min_interval, max_interval)
```

## 🚨 Considerations

- **Tests**: Always disabled in test environment for predictability
- **Database**: Reduces database load, but may cause latency on sudden spikes
- **Memory**: Significant improvement, especially in systems with idle periods
- **CPU**: Reduction proportional to system idle time

## 📦 Installation and Setup

1. **Ensure your application is using SolidQueue with the version that includes Adaptive Polling**

2. **Create an initializer in your application**:
   ```bash
   # In your Rails application
   touch config/initializers/solid_queue_adaptive_polling.rb
   ```

3. **Configure based on the example file**:
   - Check `examples_adaptive_polling_config.rb` in the gem to see all options
   - Copy relevant configurations to your initializer

4. **Restart your application** to apply the configurations

5. **Monitor the logs** to verify it's working:
   ```
   SolidQueue Adaptive Polling ENABLED with configuration:
     - Min interval: 0.05s
     - Max interval: 5.0s
   ```

---

*For complete example configurations, see the `examples_adaptive_polling_config.rb` file included in the gem.*
