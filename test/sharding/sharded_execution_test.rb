# frozen_string_literal: true

require "test_helper"

# These tests run only when the queue database is sharded, which requires
# setting SOLID_QUEUE_SHARDED when running them:
#   SOLID_QUEUE_SHARDED=1 bin/rails test test/sharding
return unless SolidQueue.sharded?

class ShardedExecutionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @workers = []
    @previous_heartbeat_interval = SolidQueue.process_heartbeat_interval
    SolidQueue.process_heartbeat_interval = 0.2.seconds
  end

  teardown do
    @workers.each(&:stop)
    SolidQueue.process_heartbeat_interval = @previous_heartbeat_interval

    on_each_shard { destroy_records }
  end

  test "workers pinned to each shard run the jobs enqueued there" do
    active_jobs = 20.times.map { StoreResultJob.new(:pinned) }
    ActiveJob.perform_all_later(active_jobs)
    enqueued_counts = jobs_count_per_shard

    SolidQueue.shards.each { |shard| start_worker_on(shard) }
    wait_for_jobs_to_finish_on_all_shards

    assert_equal 20, JobResult.where(status: "completed", value: "pinned").count
    on_each_shard do |shard|
      assert_equal enqueued_counts[shard], SolidQueue::Job.where.not(finished_at: nil).count
      assert_equal 0, SolidQueue::ReadyExecution.count
      assert_equal 0, SolidQueue::ClaimedExecution.count
    end
  end

  test "workers don't touch jobs enqueued on other shards" do
    20.times { AddToBufferJob.perform_later("hey") }
    enqueued_counts = jobs_count_per_shard
    first_shard, second_shard = SolidQueue.shards

    start_worker_on(first_shard)
    wait_while_with_timeout(3.seconds) { on_shard(first_shard) { SolidQueue::Job.where(finished_at: nil).any? } }

    on_shard(first_shard) do
      assert_equal enqueued_counts[first_shard], SolidQueue::Job.where.not(finished_at: nil).count
    end
    on_shard(second_shard) do
      assert_equal 0, SolidQueue::Job.where.not(finished_at: nil).count
      assert_equal enqueued_counts[second_shard], SolidQueue::ReadyExecution.count
    end
  end

  test "failures are recorded on the shard where the job ran" do
    active_job = StoreResultJob.perform_later(:failing, exception: ExpectedTestError)
    shard = SolidQueue::Job.shard_for(active_job)

    start_worker_on(shard)
    wait_while_with_timeout(3.seconds) { on_shard(shard) { SolidQueue::FailedExecution.none? } }

    on_shard(shard) do
      assert_equal 1, SolidQueue::FailedExecution.count
      assert_equal active_job.job_id, SolidQueue::FailedExecution.sole.job.active_job_id
    end
    (SolidQueue.shards - [ shard ]).each do |other_shard|
      on_shard(other_shard) { assert_equal 0, SolidQueue::FailedExecution.count }
    end
  end

  test "workers register and heartbeat on their own shard" do
    first_shard, second_shard = SolidQueue.shards

    start_worker_on(second_shard)
    wait_while_with_timeout(2.seconds) { on_shard(second_shard) { SolidQueue::Process.none? } }

    process = on_shard(second_shard) { SolidQueue::Process.sole }
    assert_equal "Worker", process.kind
    assert_equal second_shard.to_s, process.metadata["shard"]
    on_shard(first_shard) { assert_equal 0, SolidQueue::Process.count }

    # The heartbeat runs in its own thread, so it needs to find the process
    # record on the worker's shard by itself
    wait_while_with_timeout(2.seconds) do
      on_shard(second_shard) { SolidQueue::Process.sole.last_heartbeat_at == process.last_heartbeat_at }
    end
    assert_operator on_shard(second_shard) { SolidQueue::Process.sole.last_heartbeat_at }, :>, process.last_heartbeat_at
  end

  private
    def start_worker_on(shard)
      SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: 0.1, shard: shard).tap do |worker|
        worker.start
        @workers << worker
      end
    end

    def wait_for_jobs_to_finish_on_all_shards(timeout = 3.seconds)
      wait_while_with_timeout(timeout) do
        SolidQueue.shards.sum { |shard| on_shard(shard) { SolidQueue::Job.where(finished_at: nil).count } }.positive?
      end
    end
end
