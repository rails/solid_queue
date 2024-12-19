# frozen_string_literal: true

require "test_helper"

class RecurringTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork(skip_recurring: false)
    # 1 supervisor + 2 workers + 1 dispatcher + 1 scheduler
    wait_for_registered_processes(5, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::Process.destroy_all
    SolidQueue::Job.destroy_all
    SolidQueue::RecurringTask.delete_all
    JobResult.delete_all
  end

  test "enqueue and process periodic tasks" do
    wait_for_jobs_to_be_enqueued(2, timeout: 2.5.seconds)
    wait_for_jobs_to_finish_for(2.5.seconds)

    terminate_process(@pid)

    skip_active_record_query_cache do
      assert SolidQueue::Job.count >= 2
      SolidQueue::Job.all.each do |job|
        assert_equal "periodic_store_result", job.recurring_execution.task_key
        assert_equal "StoreResultJob", job.class_name
      end

      assert JobResult.count >= 2
      JobResult.all.each do |result|
        assert_equal "custom_status", result.status
        assert_equal "42", result.value
      end
    end
  end

  test "persist and delete configured tasks" do
    configured_task = { periodic_store_result: { class: "StoreResultJob", schedule: "every second" } }
    # Wait for concurrency schedule loading after process registration
    sleep(0.5)

    assert_recurring_tasks configured_task
    terminate_process(@pid)

    task = SolidQueue::RecurringTask.find_by(key: "periodic_store_result")
    task.update!(class_name: "StoreResultJob", schedule: "every minute", arguments: [ 42 ])

    @pid = run_supervisor_as_fork(skip_recurring: false)
    wait_for_registered_processes(5, timeout: 3.second)

    # Wait for concurrency schedule loading after process registration
    sleep(0.5)

    assert_recurring_tasks configured_task

    another_task = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: [ 42 ] } }
    scheduler1 = SolidQueue::Scheduler.new(recurring_tasks: another_task).tap(&:start)
    wait_for_registered_processes(6, timeout: 1.second)

    assert_recurring_tasks another_task

    updated_task = { example_task: { class: "AddToBufferJob", schedule: "every minute" } }
    scheduler2 = SolidQueue::Scheduler.new(recurring_tasks: updated_task).tap(&:start)
    wait_for_registered_processes(7, timeout: 1.second)

    assert_recurring_tasks updated_task

    terminate_process(@pid)
    scheduler1.stop
    scheduler2.stop
  end

  private
    def assert_recurring_tasks(expected_tasks)
      skip_active_record_query_cache do
        assert_equal expected_tasks.count, SolidQueue::RecurringTask.count

        expected_tasks.each do |key, attrs|
          task = SolidQueue::RecurringTask.find_by(key: key)
          assert task.present?

          assert_equal(attrs[:schedule], task.schedule) if attrs[:schedule]
          assert_equal(attrs[:class], task.class_name) if attrs[:class]
          assert_equal(attrs[:args], task.arguments) if attrs[:args]
        end
      end
    end
end
