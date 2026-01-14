require "test_helper"

class SchedulerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "recurring schedule" do
    recurring_tasks = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: 42 } }
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_tasks).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Scheduler", process.kind

    assert_metadata process, recurring_schedule: [ "example_task" ]
  ensure
    scheduler.stop
  end

  test "run more than one instance of the scheduler with recurring tasks" do
    recurring_tasks = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }
    schedulers = 2.times.collect do
      SolidQueue::Scheduler.new(recurring_tasks: recurring_tasks)
    end

    schedulers.each(&:start)
    wait_while_with_timeout(3.seconds) { SolidQueue::RecurringExecution.count < 2 }
    schedulers.each(&:stop)

    skip_active_record_query_cache do
      assert SolidQueue::RecurringExecution.count >= 2, "Expected at least 2 recurring executions, got #{SolidQueue::RecurringExecution.count}"
      assert_equal SolidQueue::Job.count, SolidQueue::RecurringExecution.count
      run_at_times = SolidQueue::RecurringExecution.all.map(&:run_at).sort
      0.upto(run_at_times.length - 2) do |i|
        time_diff = run_at_times[i + 1] - run_at_times[i]
        assert_in_delta 1, time_diff, 0.001, "Expected run_at times to be 1 second apart, got #{time_diff}. All run_at times: #{run_at_times.inspect}"
      end
    end
  end
end
