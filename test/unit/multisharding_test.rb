require "test_helper"

class MultishardingTest < ActiveSupport::TestCase
  test "jobs are enqueued in the right shard" do
    assert_difference -> { SolidQueue::Job.count }, 1 do
      assert_difference -> { connected_to_shard_two { SolidQueue::Job.count } }, 1 do
        AddToBufferJob.perform_later "hey!"
        ShardTwoJob.perform_later "coucou!"
      end
    end
  end

  test "jobs are enqueued in the right shard no matter the primary shard" do
    assert_difference -> { SolidQueue::Job.count }, 1 do
      change_active_shard_to(:queue_shard_two) { AddToBufferJob.perform_later "hey!" }
    end
  end

  test "shard_selection_lambda can override which shard is used to enqueue individual jobs" do
    shard_selection_lambda = ->(active_job:, active_jobs:) { :queue_shard_two if active_job.arguments.first == "hey!" }

    with_shard_selection_lambda(shard_selection_lambda) do
      assert_difference -> { connected_to_shard_two { SolidQueue::Job.count } }, 1 do
        AddToBufferJob.perform_later "hey!"
      end
    end
  end

  test "jobs are enqueued for later in the right shard" do
    assert_difference -> { SolidQueue::ScheduledExecution.count }, 1 do
      assert_difference -> { connected_to_shard_two { SolidQueue::ScheduledExecution.count } }, 1 do
        AddToBufferJob.set(wait: 1).perform_later "hey!"
        ShardTwoJob.set(wait: 1).perform_later "coucou!"
      end
    end
  end

  test "jobs are enqueued in bulk in the right shard" do
    active_jobs = [
      AddToBufferJob.new(2),
      ShardTwoJob.new(6),
      AddToBufferJob.new(3),
      ShardTwoJob.new(7)
    ]

    assert_difference -> { SolidQueue::Job.count }, 2 do
      assert_difference -> { connected_to_shard_two { SolidQueue::Job.count } }, 2 do
        ActiveJob.perform_all_later(active_jobs)
      end
    end
  end

  test "shard_selection_lambda can override which shard is used to enqueue jobs in bulk" do
    active_jobs = [
      AddToBufferJob.new(2),
      ShardTwoJob.new(6),
      AddToBufferJob.new(3),
      ShardTwoJob.new(7)
    ]
    shard_selection_lambda = ->(active_job:, active_jobs:) { :queue_shard_two if active_jobs.size == 2 }

    with_shard_selection_lambda(shard_selection_lambda) do
      assert_difference -> { SolidQueue::Job.count }, 0 do
        assert_difference -> { connected_to_shard_two { SolidQueue::Job.count } }, 4 do
          ActiveJob.perform_all_later(active_jobs)
        end
      end
    end
  end

  private

  def with_shard_selection_lambda(lambda, &block)
    SolidQueue.shard_selection_lambda = lambda
    block.call
  ensure
    SolidQueue.shard_selection_lambda = nil
  end
end
