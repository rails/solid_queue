require "test_helper"

class SolidQueue::CoalescingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.destroy_all
    SolidQueue::Batch.destroy_all
  end

  test "calls with the same key share one pending job" do
    first = CoalescedJob.perform_later("a")
    second = CoalescedJob.perform_later("a")
    other = CoalescedJob.perform_later("b")

    assert_equal 2, SolidQueue::Job.count
    assert_equal :created, first.coalesce_status
    assert_equal :discarded, second.coalesce_status
    assert_equal first.provider_job_id, second.provider_job_id
    assert_not_equal first.provider_job_id, other.provider_job_id
  end

  test "keys are scoped to the job class" do
    other_class = Class.new(CoalescedJob) { def self.name = "OtherCoalescedJob" }

    CoalescedJob.perform_later("a")
    other_class.perform_later("a")

    assert_equal 2, SolidQueue::Job.count
  end

  test "keys are scoped to the batch" do
    2.times { SolidQueue::Batch.enqueue { CoalescedJob.perform_later("a") } }
    CoalescedJob.perform_later("a")

    assert_equal 3, SolidQueue::Job.count
  end

  test "coalescing before the migration raises and leaves other jobs alone" do
    SolidQueue::CoalesceKey.stubs(:migrated?).returns(false)

    assert_raises(SolidQueue::CoalesceKey::PendingMigrations) { CoalescedJob.perform_later("a") }
    assert_raises(SolidQueue::CoalesceKey::PendingMigrations) { ActiveJob.perform_all_later([ CoalescedJob.new("a") ]) }

    AddToBufferJob.perform_later(1)
    assert_equal 1, SolidQueue::ReadyExecution.claim("*", 10, 42).size
  end

  test "scheduled calls share one pending job" do
    first = CoalescedJob.set(wait: 5.minutes).perform_later("a")
    second = CoalescedJob.set(wait: 10.minutes).perform_later("a")

    assert_equal 1, SolidQueue::ScheduledExecution.count
    assert_equal first.provider_job_id, second.provider_job_id
  end

  test "a call after the pending job starts queues the next one" do
    first = CoalescedJob.perform_later("a")
    SolidQueue::ReadyExecution.claim("*", 10, 42)

    second = CoalescedJob.perform_later("a")
    third = CoalescedJob.perform_later("a")

    assert_equal :created, second.coalesce_status
    assert_not_equal first.provider_job_id, second.provider_job_id
    assert_equal second.provider_job_id, third.provider_job_id
  end

  test "a call after the pending job is discarded queues a new one" do
    first = CoalescedJob.perform_later("a")
    SolidQueue::Job.find(first.provider_job_id).discard

    second = CoalescedJob.perform_later("a")

    assert_equal :created, second.coalesce_status
    assert_equal 1, SolidQueue::Job.count
  end

  test "retries aren't coalesced" do
    CoalescedJob.perform_later("a")
    retry_job = CoalescedJob.new("a").tap { |job| job.executions = 1 }

    assert_difference -> { SolidQueue::Job.count }, +1 do
      retry_job.enqueue
    end
    assert_nil retry_job.coalesce_status
  end

  test "bulk enqueue coalesces and counts only created jobs" do
    jobs = [ CoalescedJob.new("a"), CoalescedJob.new("a"), CoalescedJob.new("b"), AddToBufferJob.new(1) ]
    ActiveJob.perform_all_later(jobs)

    assert_equal 3, jobs.count(&:successfully_enqueued?)
    assert_equal 3, SolidQueue::Job.count
    assert_equal [ :created, :discarded, :created, nil ], jobs.map(&:coalesce_status)
  end

  test "bulk enqueue of only coalesced jobs" do
    jobs = [ CoalescedJob.new("a"), CoalescedJob.new("a") ]
    ActiveJob.perform_all_later(jobs)

    assert_equal 1, SolidQueue::Job.count
    assert_equal [ :created, :discarded ], jobs.map(&:coalesce_status)
  end

  test "database errors when coalescing raise enqueue errors" do
    SolidQueue::CoalesceKey.stubs(:admit).raises(ActiveRecord::StatementInvalid, "boom")

    assert_raises SolidQueue::Job::EnqueueError do
      SolidQueue::Job.enqueue(CoalescedJob.new("a"))
    end
  end

  test "concurrent calls with the same key share one pending job" do
    jobs = 10.times.map { CoalescedJob.new("a") }
    go = Concurrent::Event.new

    threads = jobs.map do |job|
      Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          go.wait
          job.enqueue
        end
      end
    end
    go.set
    threads.each(&:join)

    assert_equal 1, SolidQueue::Job.count
    assert_equal [ SolidQueue::Job.last.id ], jobs.map(&:provider_job_id).uniq
    assert_equal 1, jobs.count { |job| job.coalesce_status == :created }
  end
end
