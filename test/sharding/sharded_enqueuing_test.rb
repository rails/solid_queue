# frozen_string_literal: true

require "test_helper"

# These tests run only when the queue database is sharded, which requires
# setting SOLID_QUEUE_SHARDED when running them:
#   SOLID_QUEUE_SHARDED=1 bin/rails test test/sharding
return unless SolidQueue.sharded?

class ShardedEnqueuingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    on_each_shard { SolidQueue::Job.delete_all }
    on_each_shard { SolidQueue::Semaphore.delete_all }
  end

  test "distribute jobs across all shards by Active Job ID" do
    40.times { AddToBufferJob.perform_later("hey") }

    counts = jobs_count_per_shard
    assert_equal 40, counts.values.sum
    counts.each do |shard, count|
      assert count.positive?, "Expected some jobs in #{shard}"
    end
  end

  test "pick the shard deterministically from the Active Job ID" do
    active_job = AddToBufferJob.perform_later("hey")

    shard = SolidQueue::Job.shard_for(active_job)
    9.times { assert_equal shard, SolidQueue::Job.shard_for(active_job) }

    on_shard(shard) do
      assert SolidQueue::Job.exists?(active_job_id: active_job.job_id)
    end
  end

  test "enqueue jobs with the same concurrency key on the same shard" do
    result = JobResult.create!(queue_name: "default")
    jobs = 20.times.map { NonOverlappingUpdateResultJob.perform_later(result, name: "A") }

    shards = jobs.map { |job| SolidQueue::Job.shard_for(job) }.uniq
    assert_equal 1, shards.size

    on_shard(shards.first) do
      assert_equal 20, SolidQueue::Job.count
      assert_equal 1, SolidQueue::ReadyExecution.count
      assert_equal 19, SolidQueue::BlockedExecution.count
      assert_equal 1, SolidQueue::Semaphore.count
    end
  end

  test "enqueue jobs in bulk grouped by shard" do
    active_jobs = 30.times.map { AddToBufferJob.new("hey") }

    ActiveJob.perform_all_later(active_jobs)

    assert active_jobs.all?(&:successfully_enqueued?)
    assert active_jobs.all?(&:provider_job_id)

    expected_counts = active_jobs.group_by { |job| SolidQueue::Job.shard_for(job) }.transform_values(&:count)
    assert_equal expected_counts, jobs_count_per_shard.select { |_, count| count.positive? }

    active_jobs.each do |active_job|
      on_shard(SolidQueue::Job.shard_for(active_job)) do
        assert_equal active_job.provider_job_id, SolidQueue::Job.find_by(active_job_id: active_job.job_id).id
      end
    end
  end

  test "jobs keep their shard when retried" do
    active_job = AddToBufferJob.perform_later("hey")
    shard = SolidQueue::Job.shard_for(active_job)

    # Retried and resumed jobs keep their Active Job ID, so they hash to the same shard
    retried_job = AddToBufferJob.deserialize(active_job.serialize)
    assert_equal shard, SolidQueue::Job.shard_for(retried_job)
  end

  test "code that doesn't select a shard operates on the first one" do
    on_shard(SolidQueue.shards.first) { AddToBufferJob.new("hey").tap { |j| j.scheduled_at = Time.current }.then { |j| SolidQueue::Job.enqueue(j) } }

    assert_equal SolidQueue::Job.connection_pool, SolidQueue::Record.connected_to(shard: SolidQueue.shards.first) { SolidQueue::Job.connection_pool }
  end
end
