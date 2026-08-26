# frozen_string_literal: true

require "test_helper"

class SolidQueue::ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    DynamicLimitJob.limits = Hash.new(2)
    DynamicLimitJob.evaluations = Hash.new(0)
    SolidQueue::Concurrency::LimitCache.clear
  end

  test "integer to: still admits one and blocks the rest" do
    result = JobResult.create!(queue_name: "default")
    3.times { NonOverlappingUpdateResultJob.perform_later(result) }

    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::BlockedExecution.count
  end

  test "proc to: admits up to the evaluated limit" do
    DynamicLimitJob.limits[7] = 2
    4.times { DynamicLimitJob.perform_later(7) }

    assert_equal 2, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::BlockedExecution.count
    assert_equal 2, semaphore_for("tenant/7").limit
  end

  test "to: 0 never admits" do
    DynamicLimitJob.limits[9] = 0
    DynamicLimitJob.perform_later(9)

    assert_equal 0, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
    assert_equal 0, semaphore_for("tenant/9").value
    assert_equal 0, semaphore_for("tenant/9").limit
  end

  test "proc results are memoized in process memory by key" do
    DynamicLimitJob.limits[3] = 5
    3.times { DynamicLimitJob.perform_later(3) }

    assert_equal 1, DynamicLimitJob.evaluations[3]
  end

  test "proc memo is shared by threads in the same process" do
    DynamicLimitJob.limits[3] = 5
    DynamicLimitJob.perform_later(3)
    assert_equal 1, DynamicLimitJob.evaluations[3]

    threads = 4.times.map { Thread.new { DynamicLimitJob.perform_later(3) } }
    threads.each(&:join)

    assert_equal 1, DynamicLimitJob.evaluations[3]
  end

  test "refresh to a higher limit unblocks without a job finishing" do
    DynamicLimitJob.limits[4] = 1
    3.times { DynamicLimitJob.perform_later(4) }
    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::BlockedExecution.count

    DynamicLimitJob.limits[4] = 3
    released = SolidQueue::Concurrency.refresh("tenant/4", to: 3)

    assert_equal 2, released
    assert_equal 3, SolidQueue::ReadyExecution.count
    assert_equal 0, SolidQueue::BlockedExecution.count
    assert_equal 3, semaphore_for("tenant/4").limit
  end

  test "refresh to 0 reblocks every ready job" do
    DynamicLimitJob.limits[2] = 2
    2.times { DynamicLimitJob.perform_later(2) }
    assert_equal 2, SolidQueue::ReadyExecution.count

    SolidQueue::Concurrency.refresh("tenant/2", to: 0)

    assert_equal 0, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::BlockedExecution.count
    assert_equal 0, semaphore_for("tenant/2").limit
    assert_equal 0, semaphore_for("tenant/2").value
  end

  test "refresh to a lower limit reblocks excess ready jobs" do
    DynamicLimitJob.limits[5] = 3
    3.times { DynamicLimitJob.perform_later(5) }
    assert_equal 3, SolidQueue::ReadyExecution.count

    DynamicLimitJob.limits[5] = 1
    SolidQueue::Concurrency.refresh("tenant/5", to: 1)

    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_equal 2, SolidQueue::BlockedExecution.count
    assert_equal 1, semaphore_for("tenant/5").limit
  end

  test "changing the proc without refresh does not admit more until wait sees the new limit" do
    DynamicLimitJob.limits[8] = 1
    DynamicLimitJob.perform_later(8)
    DynamicLimitJob.perform_later(8)
    assert_equal 1, SolidQueue::ReadyExecution.count

    DynamicLimitJob.limits[8] = 2
    SolidQueue::Concurrency::LimitCache.clear
    DynamicLimitJob.perform_later(8)

    assert_equal 2, SolidQueue::ReadyExecution.count
    assert_equal 1, SolidQueue::BlockedExecution.count
  end

  test "pre-existing semaphore with null limit still uses remaining-slot math" do
    DynamicLimitJob.limits[6] = 2
    DynamicLimitJob.perform_later(6)
    semaphore_for("tenant/6").update_columns(limit: nil)

    SolidQueue::Concurrency::LimitCache.clear
    DynamicLimitJob.perform_later(6)

    assert_equal 2, SolidQueue::ReadyExecution.count
    assert_equal 2, semaphore_for("tenant/6").limit
  end

  private
    def semaphore_for(key)
      SolidQueue::Semaphore.find_by!(key: key)
    end
end
