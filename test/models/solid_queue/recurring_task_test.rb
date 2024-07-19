require "test_helper"

class SolidQueue::RecurringTaskTest < ActiveSupport::TestCase
  class JobWithoutArguments < ApplicationJob
    def perform
      JobBuffer.add "job_without_arguments"
    end
  end

  class JobWithRegularHashArguments < ApplicationJob
    def perform(value, options)
      JobBuffer.add [ value, options[:value] ]
    end
  end

  class JobWithKeywordArgument < ApplicationJob
    def perform(value, value_kwarg:)
      JobBuffer.add [ value, value_kwarg ]
    end
  end

  class JobWithMultipleTypeArguments < ApplicationJob
    def perform(value, options = {}, **kwargs)
      JobBuffer.add [ value, options[:value], kwargs[:value_kwarg] ]
    end
  end

  class JobUsingAsyncAdapter < ApplicationJob
    self.queue_adapter = :async

    def perform
      JobBuffer.add "job_using_async_adapter"
    end
  end

  setup do
    @worker = SolidQueue::Worker.new(queues: "*")
    @worker.mode = :inline
  end

  test "job without arguments" do
    task = recurring_task_with(class_name: "JobWithoutArguments")
    enqueue_and_assert_performed_with_result task, "job_without_arguments"
  end

  test "job with regular hash argument" do
    task = recurring_task_with(class_name: "JobWithRegularHashArguments", args: [ "regular_hash_argument", { value: 42, not_used: 24 } ])

    enqueue_and_assert_performed_with_result task, [ "regular_hash_argument", 42 ]
  end

  test "job with keyword argument" do
    task = recurring_task_with(class_name: "JobWithKeywordArgument", args: [ "keyword_argument", { value_kwarg: [ 42, 24 ] } ])
    enqueue_and_assert_performed_with_result task, [ "keyword_argument", [ 42, 24 ] ]
  end

  test "job with arguments of multiple types" do
    task = recurring_task_with(class_name: "JobWithMultipleTypeArguments", args:
      [ "multiple_types", { value: "regular_hash_value", not_used: 28 }, value_kwarg: 42, not_used: 32 ])
    enqueue_and_assert_performed_with_result task, [ "multiple_types", "regular_hash_value", 42 ]
  end

  test "job with arguments of multiple types ignoring optional regular hash" do
    task = recurring_task_with(class_name: "JobWithMultipleTypeArguments", args:
      [ "multiple_types", value: "regular_hash_value", value_kwarg: 42, not_used: 32 ])
    enqueue_and_assert_performed_with_result task, [ "multiple_types", nil, 42 ]
  end

  test "job using a different adapter" do
    task = recurring_task_with(class_name: "JobUsingAsyncAdapter")
    previous_size = JobBuffer.size

    task.enqueue(at: Time.now)
    wait_while_with_timeout!(0.5.seconds) { JobBuffer.size == previous_size }

    assert_equal "job_using_async_adapter", JobBuffer.last_value
  end

  test "error when enqueuing job before recording task" do
    SolidQueue::Job.stubs(:create!).raises(ActiveRecord::Deadlocked)

    task = recurring_task_with(class_name: "JobWithoutArguments")
    assert_no_difference -> { SolidQueue::Job.count } do
      task.enqueue(at: Time.now)
    end
  end

  test "error when enqueuing job using another adapter that raises ActiveJob::EnqueueError" do
    ActiveJob::QueueAdapters::AsyncAdapter.any_instance.stubs(:enqueue).raises(ActiveJob::EnqueueError)
    previous_size = JobBuffer.size

    task = recurring_task_with(class_name: "JobUsingAsyncAdapter")
    task.enqueue(at: Time.now)

    wait_while_with_timeout(0.5.seconds) { JobBuffer.size == previous_size }

    assert_equal previous_size, JobBuffer.size
  end

  test "valid and invalid schedules" do
    assert_not recurring_task_with(class_name: "JobWithoutArguments", schedule: "once a year").valid?
    assert_not recurring_task_with(class_name: "JobWithoutArguments", schedule: "tomorrow").valid?

    task = recurring_task_with(class_name: "JobWithoutArguments", schedule: "every Thursday at 1 AM")
    assert task.valid?
    # At 1 AM on the 4th day of the week
    assert task.to_s.ends_with? "[ 0 1 * * 4 ]"

    task = recurring_task_with(class_name: "JobWithoutArguments", schedule: "every month")
    assert task.valid?
    # At 12:00 AM, on day 1 of the month
    assert task.to_s.ends_with? "[ 0 0 1 * * ]"

    task = recurring_task_with(class_name: "JobWithoutArguments", schedule: "every second")
    assert task.valid?
    assert task.to_s.ends_with? "[ * * * * * * ]"

    # Empty schedule
    assert_not SolidQueue::RecurringTask.new(key: "task-id", class_name: "SolidQueue::RecurringTaskTest::JobWithoutArguments").valid?
  end

  test "undefined job class" do
    assert_not recurring_task_with(class_name: "UnknownJob").valid?

    # Empty class name
    assert_not SolidQueue::RecurringTask.new(key: "task-id", schedule: "every minute").valid?
  end

  private
    def enqueue_and_assert_performed_with_result(task, result)
      assert_difference [ -> { SolidQueue::Job.count }, -> { SolidQueue::ReadyExecution.count } ], +1 do
        task.enqueue(at: Time.now)
      end

      assert_difference -> { JobBuffer.size }, +1 do
        @worker.start
      end

      assert_equal result, JobBuffer.last_value
    end

    def recurring_task_with(class_name:, schedule: "every hour", args: nil)
      SolidQueue::RecurringTask.new(key: "task-id", class_name: "SolidQueue::RecurringTaskTest::#{class_name}", schedule: schedule, arguments: args)
    end
end
