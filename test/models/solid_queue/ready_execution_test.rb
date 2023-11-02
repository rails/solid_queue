require "test_helper"

class SolidQueue::ReadyExecutionTest < ActiveSupport::TestCase
  setup do
    @jobs = SolidQueue::Job.where(queue_name: "fixtures")
    @jobs.each(&:prepare_for_execution)
  end

  test "claim all jobs for existing queue" do
    assert_claimed_jobs(@jobs.count) do
      SolidQueue::ReadyExecution.claim("fixtures", @jobs.count + 1, 42)
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
      SolidQueue::ReadyExecution.claim("fixtures", 2, 42)
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
    job = solid_queue_jobs(:add_to_buffer_job)
    job.prepare_for_execution

    assert_claimed_jobs(1) do
      job.ready_execution.claim(42)
    end

    assert_not job.reload.ready?
    assert job.claimed?
  end

  test "claim jobs using a list of queues" do
    (SolidQueue::Job.all - @jobs).each(&:prepare_for_execution)

    assert_claimed_jobs(SolidQueue::Job.count) do
      SolidQueue::ReadyExecution.claim("fixtures,background", SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using a wildcard" do
    (SolidQueue::Job.all - @jobs).each(&:prepare_for_execution)

    assert_claimed_jobs(SolidQueue::Job.count) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using a wildcard and having paused queues" do
    other_jobs = SolidQueue::Job.all - @jobs
    other_jobs.each(&:prepare_for_execution)

    SolidQueue::Queue.find_by_name("fixtures").pause

    assert_claimed_jobs(other_jobs.count) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, 42)
    end
  end

  test "claim jobs using queue prefixes" do
    assert_claimed_jobs(2) do
      SolidQueue::ReadyExecution.claim("fix*", 2, 42)
    end

    @jobs.order(:priority).first(2).each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end
  end

  test "claim jobs using both exact names and prefixes" do
    (SolidQueue::Job.all - @jobs).each(&:prepare_for_execution)

    assert_claimed_jobs(SolidQueue::Job.count) do
      SolidQueue::ReadyExecution.claim("fix*,background", SolidQueue::Job.count + 1, 42)
    end
  end

  private
    def assert_claimed_jobs(count, &block)
      assert_difference -> { SolidQueue::ReadyExecution.count } => -count, -> { SolidQueue::ClaimedExecution.count } => +count do
        block.call
      end
    end
end
