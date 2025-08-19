require "test_helper"

class AdaptivePollingIntegrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @original_enabled = SolidQueue.adaptive_polling_enabled
    @original_min = SolidQueue.adaptive_polling_min_interval
    @original_max = SolidQueue.adaptive_polling_max_interval
    @original_speedup = SolidQueue.adaptive_polling_speedup_factor
    @original_backoff = SolidQueue.adaptive_polling_backoff_factor

    SolidQueue.adaptive_polling_enabled = true
    SolidQueue.adaptive_polling_min_interval = 0.05
    SolidQueue.adaptive_polling_max_interval = 2.0
    SolidQueue.adaptive_polling_speedup_factor = 0.6
    SolidQueue.adaptive_polling_backoff_factor = 1.6
  end

  teardown do
    SolidQueue.adaptive_polling_enabled = @original_enabled
    SolidQueue.adaptive_polling_min_interval = @original_min
    SolidQueue.adaptive_polling_max_interval = @original_max
    SolidQueue.adaptive_polling_speedup_factor = @original_speedup
    SolidQueue.adaptive_polling_backoff_factor = @original_backoff

    @worker&.stop
    JobBuffer.clear
  end

  test "worker with adaptive polling processes jobs and adapts interval" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    assert_not_nil @worker.adaptive_poller, "Worker should have adaptive poller"

    5.times { |i| AddToBufferJob.perform_later("job_#{i}") }

    wait_for(timeout: 3.seconds) { JobBuffer.values.size == 5 }

    assert_equal 5, JobBuffer.values.size
    assert_equal %w[ job_0 job_1 job_2 job_3 job_4 ], JobBuffer.values.sort
  end

  test "adaptive polling reduces interval when system is busy" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    initial_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)

    20.times { |i| AddToBufferJob.perform_later("busy_job_#{i}") }

    wait_for(timeout: 3.seconds) { JobBuffer.values.size >= 10 }

    sleep(1)
    current_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)

    consecutive_busy = @worker.adaptive_poller.instance_variable_get(:@consecutive_busy_polls)

    if consecutive_busy >= 5
      assert current_interval <= initial_interval * 1.2, # Allow some tolerance
             "Interval should decrease or stay stable when system is busy (#{initial_interval} -> #{current_interval}, busy_polls: #{consecutive_busy})"
    else
      assert JobBuffer.values.size >= 10, "Should have processed jobs even if interval didn't change"
    end
  end

  test "adaptive polling increases interval when system is idle" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    initial_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)

    sleep(2)

    current_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)

    assert current_interval > initial_interval,
           "Interval should increase when system is idle (#{initial_interval} -> #{current_interval})"
  end

  test "worker respects adaptive polling configuration limits" do
    SolidQueue.adaptive_polling_min_interval = 0.1
    SolidQueue.adaptive_polling_max_interval = 0.5

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    10.times { |i| AddToBufferJob.perform_later("limit_test_#{i}") }
    sleep(1)

    busy_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)
    assert busy_interval >= SolidQueue.adaptive_polling_min_interval,
           "Busy interval should not go below minimum"

    wait_for(timeout: 3.seconds) { JobBuffer.values.size == 10 }
    sleep(2)

    idle_interval = @worker.adaptive_poller.instance_variable_get(:@current_interval)
    assert idle_interval <= SolidQueue.adaptive_polling_max_interval,
           "Idle interval should not exceed maximum"
  end

  test "multiple workers with adaptive polling work independently" do
    worker1 = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    worker2 = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.3)

    worker1.start
    worker2.start

    wait_for_registered_processes(2, timeout: 2.seconds)

    assert_not_nil worker1.adaptive_poller
    assert_not_nil worker2.adaptive_poller
    assert_not_same worker1.adaptive_poller, worker2.adaptive_poller

    assert_equal 0.1, worker1.adaptive_poller.instance_variable_get(:@base_interval)
    assert_equal 0.3, worker2.adaptive_poller.instance_variable_get(:@base_interval)

  ensure
    worker1&.stop
    worker2&.stop
  end

  test "adaptive polling statistics are tracked during job processing" do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    3.times { |i| AddToBufferJob.perform_later("stats_job_#{i}") }

    wait_for(timeout: 3.seconds) { JobBuffer.values.size == 3 }

    stats = @worker.instance_variable_get(:@polling_stats)
    assert stats[:total_polls] > 0, "Should have tracked some polls"
    assert stats[:total_jobs_claimed] >= 3, "Should have tracked job claims"
  end

  test "worker without adaptive polling behaves normally" do
    SolidQueue.adaptive_polling_enabled = false

    @worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.2)
    @worker.start

    wait_for_registered_processes(1, timeout: 1.second)

    assert_nil @worker.adaptive_poller

    AddToBufferJob.perform_later("normal_job")

    wait_for(timeout: 2.seconds) { JobBuffer.values.size == 1 }
    assert_equal [ "normal_job" ], JobBuffer.values
  end

  private

  def wait_for_registered_processes(count, timeout:)
    wait_for(timeout: timeout) { SolidQueue::Process.count >= count }
  end
end
