require "test_helper"

class MultishardingTest < ActiveSupport::TestCase
  test "jobs are enqueued in the right shard" do
    assert_difference -> { SolidQueue::Job.count }, 1 do
      assert_difference -> do
                          ActiveRecord::Base.connected_to(
                            shard: :queue_shard_two
                          ) { SolidQueue::Job.count }
                        end,
                        1 do
        AddToBufferJob.perform_later "hey!"
        ShardTwoJob.perform_later "coucou!"
      end
    end
  end

  test "jobs are enqueued for later in the right shard" do
    assert_difference -> { SolidQueue::ScheduledExecution.count }, 1 do
      assert_difference -> do
                          ActiveRecord::Base.connected_to(
                            shard: :queue_shard_two
                          ) { SolidQueue::ScheduledExecution.count }
                        end,
                        1 do
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
      assert_difference -> do
                          ActiveRecord::Base.connected_to(
                            shard: :queue_shard_two
                          ) { SolidQueue::Job.count }
                        end,
                        2 do
        ActiveJob.perform_all_later(active_jobs)
      end
    end
  end
end
