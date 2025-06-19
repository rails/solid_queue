require "test_helper"

class SchedulerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "recurring schedule (only static)" do
    recurring_tasks = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: 42 } }
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_tasks).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Scheduler", process.kind

    assert_metadata process, recurring_schedule: [ "example_task" ]
  ensure
    scheduler.stop
  end

  test "recurring schedule (only dynamic)" do
    SolidQueue::RecurringTask.create(
      key: "dynamic_task", static: false, class_name: "AddToBufferJob", schedule: "every second", arguments: [ 42 ]
    )
    scheduler = SolidQueue::Scheduler.new(recurring_tasks:  {}).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Scheduler", process.kind

    assert_metadata process, recurring_schedule: [ "dynamic_task" ]
  ensure
    scheduler.stop
  end

  test "recurring schedule (static + dynamic)" do
    SolidQueue::RecurringTask.create(
      key: "dynamic_task", static: false, class_name: "AddToBufferJob", schedule: "every second", arguments: [ 42 ]
    )

    recurring_tasks = { static_task: { class: "AddToBufferJob", schedule: "every hour", args: 42 } }

    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_tasks).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Scheduler", process.kind

    assert_metadata process, recurring_schedule: [ "static_task", "dynamic_task" ]
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

  test "updates metadata after adding dynamic task post-start" do
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: {}, polling_interval: 0.1).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    # initially there are no recurring_schedule keys
    assert process.metadata, {}

    # now create a dynamic task after the scheduler has booted
    SolidQueue::RecurringTask.create(
      key:       "new_dynamic_task",
      static:    false,
      class_name: "AddToBufferJob",
      schedule:  "every second",
      arguments: [ 42 ]
    )

    sleep 1

    process.reload

    # metadata should now include the new key
    assert_metadata process, recurring_schedule: [ "new_dynamic_task" ]
  ensure
    scheduler&.stop
  end

  test "updates metadata after removing dynamic task post-start" do
    old_dynamic_task = SolidQueue::RecurringTask.create(
      key:       "old_dynamic_task",
      static:    false,
      class_name: "AddToBufferJob",
      schedule:  "every second",
      arguments: [ 42 ]
    )

    scheduler = SolidQueue::Scheduler.new(recurring_tasks: {}, polling_interval: 0.1).tap(&:start)

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    # initially there is one recurring_schedule key
    assert_metadata process, recurring_schedule: [ "old_dynamic_task" ]

    old_dynamic_task.destroy

    sleep 1

    process.reload

    # The task is unschedule after it's being removed, and it's reflected in the metadata
    assert process.metadata, {}
  ensure
    scheduler&.stop
  end
end
