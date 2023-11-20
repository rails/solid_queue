require "test_helper"

class SolidQueue::ReadyExecutionTest < ActiveSupport::TestCase
  setup do
    5.times do |i|
      AddToBufferJob.set(queue: "backend", priority: 5 - i).perform_later(i)
    end

    @jobs = SolidQueue::Job.where(queue_name: "backend")
  end

  test "claim all jobs for existing queue" do
    assert_claimed_jobs(@jobs.count) do
      SolidQueue::ReadyExecution.claim("backend", @jobs.count + 1, 42)
    end

    @jobs.each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end
  end

  test "claim jobs for queue without jobs at the moment" do
    assert_no_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::ClaimedExecution.count } ] do
      SolidQueue::ReadyExecution.claim("some_non_existing_queue", 10, 42)
    end
  end

  test "claim some jobs for existing queue" do
    assert_claimed_jobs(2) do
      SolidQueue::ReadyExecution.claim("backend", 2, 42)
    end

    @jobs.order(:priority).first(2).each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end

    @jobs.order(:priority)[2..-1].each do |job|
      assert job.reload.ready?
      assert_not job.claimed?
    end
  end

  test "claim individual job" do
    AddToBufferJob.perform_later("hey")
    job = SolidQueue::Job.last

    assert_claimed_jobs(1) do
      job.ready_execution.claim(42)
    end

    assert_not job.reload.ready?
    assert job.claimed?
  end

  test "claim jobs using a list of queues" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim(%w[ backend background ], SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using a wildcard" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using a wildcard and having paused queues" do
    AddToBufferJob.perform_later("hey")

    SolidQueue::Queue.find_by_name("backend").pause

    assert_claimed_jobs(1) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using queue prefixes" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(1) do
      SolidQueue::ReadyExecution.claim("backgr*", SolidQueue::Job.count + 1, 42)
    end

    assert @jobs.none?(&:claimed?)
  end

  test "claim jobs using both exact names and prefixes" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim(%w[ backe* background ], SolidQueue::Job.count + 1, 42)
    end
  end

  private
    def assert_claimed_jobs(count, &block)
      assert_difference -> { SolidQueue::ReadyExecution.count } => -count, -> { SolidQueue::ClaimedExecution.count } => +count do
        block.call
      end
    end
end
