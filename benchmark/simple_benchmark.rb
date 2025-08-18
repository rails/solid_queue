#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple benchmark script to demonstrate Adaptive Polling benefits
# Run with: ruby benchmark/simple_benchmark.rb

require "bundler/setup"
require "solid_queue"
require "benchmark"

# Suppress logging for cleaner output
SolidQueue.logger = Logger.new("/dev/null")

class TestJob < ApplicationJob
  queue_as :background

  def perform(work_duration = 0.01)
    sleep(work_duration)
  end
end

class SimpleBenchmark
  def initialize
    # Ensure clean state
    SolidQueue::Job.delete_all rescue nil
    SolidQueue::Process.delete_all rescue nil
  end

  def run_comparison
    puts "🚀 SolidQueue Adaptive Polling - Simple Benchmark"
    puts "=" * 55
    puts

    scenarios = [
      { name: "Idle System", jobs: 0, duration: 10 },
      { name: "Light Load", jobs: 5, duration: 10 },
      { name: "Moderate Load", jobs: 20, duration: 10 }
    ]

    scenarios.each do |scenario|
      puts "📊 Testing: #{scenario[:name]}"
      puts "-" * 30

      # Test without adaptive polling
      fixed_stats = run_scenario(
        adaptive_polling: false,
        job_count: scenario[:jobs],
        duration: scenario[:duration]
      )

      # Test with adaptive polling
      adaptive_stats = run_scenario(
        adaptive_polling: true,
        job_count: scenario[:jobs],
        duration: scenario[:duration]
      )

      # Display results
      display_comparison(fixed_stats, adaptive_stats)
      puts
    end
  end

  private

  def run_scenario(adaptive_polling:, job_count:, duration:)
    # Configure adaptive polling
    SolidQueue.adaptive_polling_enabled = adaptive_polling
    SolidQueue.adaptive_polling_min_interval = 0.05
    SolidQueue.adaptive_polling_max_interval = 2.0

    # Clean state
    SolidQueue::Job.delete_all rescue nil

    # Create jobs
    job_count.times { TestJob.perform_later(0.01) }

    # Track statistics
    start_time = Time.current
    poll_count = 0
    query_count = 0

    # Create and start worker
    worker = SolidQueue::Worker.new(
      queues: "background",
      threads: 1,
      polling_interval: 0.1
    )

    # Monitor polling in a separate thread
    monitor_thread = Thread.new do
      while Time.current - start_time < duration
        poll_count += 1
        query_count += 2 # Approximate queries per poll
        sleep(0.05) # Monitor every 50ms
      end
    end

    # Run worker for specified duration
    worker_thread = Thread.new { worker.start }
    sleep(duration)
    worker.stop

    monitor_thread.kill
    worker_thread.join

    elapsed = Time.current - start_time
    jobs_processed = job_count - (SolidQueue::Job.count rescue job_count)

    {
      adaptive_polling: adaptive_polling,
      elapsed: elapsed,
      polls_per_second: poll_count / elapsed,
      queries_per_second: query_count / elapsed,
      jobs_processed: jobs_processed,
      avg_interval: calculate_avg_interval(worker)
    }
  end

  def calculate_avg_interval(worker)
    if worker.respond_to?(:adaptive_poller) && worker.adaptive_poller
      worker.adaptive_poller.current_interval
    else
      worker.polling_interval
    end
  end

  def display_comparison(fixed, adaptive)
    poll_reduction = ((fixed[:polls_per_second] - adaptive[:polls_per_second]) / fixed[:polls_per_second] * 100).round(1)
    query_reduction = ((fixed[:queries_per_second] - adaptive[:queries_per_second]) / fixed[:queries_per_second] * 100).round(1)

    puts "  Fixed Polling:"
    puts "    Polls/sec: #{fixed[:polls_per_second].round(1)}"
    puts "    Queries/sec: #{fixed[:queries_per_second].round(1)}"
    puts "    Jobs processed: #{fixed[:jobs_processed]}"
    puts
    puts "  Adaptive Polling:"
    puts "    Polls/sec: #{adaptive[:polls_per_second].round(1)}"
    puts "    Queries/sec: #{adaptive[:queries_per_second].round(1)}"
    puts "    Jobs processed: #{adaptive[:jobs_processed]}"
    puts "    Avg interval: #{adaptive[:avg_interval].round(3)}s"
    puts
    puts "  📈 Improvements:"
    puts "    Poll reduction: #{format_change(poll_reduction)}%"
    puts "    Query reduction: #{format_change(query_reduction)}%"
    puts "    Jobs impact: #{fixed[:jobs_processed] == adaptive[:jobs_processed] ? 'No impact ✅' : 'Different ⚠️'}"
  end

  def format_change(value)
    value > 0 ? "+#{value}" : value.to_s
  end
end

# Run the benchmark
if __FILE__ == $0
  SimpleBenchmark.new.run_comparison
end
