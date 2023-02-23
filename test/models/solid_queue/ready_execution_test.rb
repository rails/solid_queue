require "test_helper"

class SolidQueue::ReadyExecutionTest < ActiveSupport::TestCase
  setup do
    @jobs = SolidQueue::Job.where(queue_name: "fixtures")
    @jobs.each(&:prepare_for_execution)
  end

  test "claim all jobs for existing queue" do
    assert_difference -> { SolidQueue::ReadyExecution.count } => -@jobs.count, -> { SolidQueue::ClaimedExecution.count } => @jobs.count do
      SolidQueue::ReadyExecution.claim("fixtures", @jobs.count + 1)
    end

    @jobs.each do |job|
      assert_nil job.reload.ready_execution
      assert job.claimed_execution.present?
    end
  end

  test "claim jobs for queue without jobs at the moment" do
    assert_no_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::ClaimedExecution.count } ] do
      SolidQueue::ReadyExecution.claim("some_non_existing_queue", 10)
    end
  end

  test "claim some jobs for existing queue" do
    assert_difference -> { SolidQueue::ReadyExecution.count } => -2, -> { SolidQueue::ClaimedExecution.count } => 2 do
      SolidQueue::ReadyExecution.claim("fixtures", 2)
    end

    @jobs.first(2).each do |job|
      assert_nil job.reload.ready_execution
      assert job.claimed_execution.present?
    end

    @jobs[2..-1].each do |job|
      assert job.reload.ready_execution.present?
      assert_nil job.claimed_execution
    end
  end

  test "claim individual job" do
    job = solid_queue_jobs(:add_to_buffer_job)
    job.prepare_for_execution

    assert_difference -> { SolidQueue::ReadyExecution.count } => -1, -> { SolidQueue::ClaimedExecution.count } => 1 do
      job.ready_execution.claim
    end

    assert_nil job.reload.ready_execution
    assert job.claimed_execution.present?
  end
end
