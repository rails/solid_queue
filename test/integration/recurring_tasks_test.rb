# frozen_string_literal: true

require "test_helper"

class RecurringTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork
    # 1 supervisor + 2 workers + 1 dispatcher
    wait_for_registered_processes(4, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::Process.destroy_all
    SolidQueue::Job.destroy_all
    SolidQueue::RecurringTask.delete_all
    JobResult.delete_all
  end

  test "enqueue and process periodic tasks" do
    wait_for_jobs_to_be_enqueued(2, timeout: 2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    terminate_process(@pid)

    skip_active_record_query_cache do
      assert SolidQueue::Job.count >= 2
      SolidQueue::Job.all.each do |job|
        assert_equal "periodic_store_result", job.recurring_execution.task_key
        assert_equal "StoreResultJob", job.class_name
      end

      assert_equal 2, JobResult.count
      JobResult.all.each do |result|
        assert_equal "custom_status", result.status
        assert_equal "42", result.value
      end
    end
  end

  test "persist and delete configured tasks" do
    configured_task = { periodic_store_result: { class: "StoreResultJob", schedule: "every second" } }

    assert_recurring_tasks configured_task
    terminate_process(@pid)
    assert_recurring_tasks []

    SolidQueue::RecurringTask.create!(key: "periodic_store_result", class_name: "StoreResultJob", schedule: "every minute", arguments: [ 42 ])

    @pid = run_supervisor_as_fork
    wait_for_registered_processes(4, timeout: 3.second)

    assert_recurring_tasks configured_task

    another_task = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: [ 42 ] } }
    dispatcher1 = SolidQueue::Dispatcher.new(concurrency_maintenance: false, recurring_tasks: another_task).tap(&:start)
    wait_for_registered_processes(5, timeout: 1.second)

    assert_recurring_tasks configured_task.merge(another_task)

    updated_task = { example_task: { class: "AddToBufferJob", schedule: "every minute" } }
    dispatcher2 = SolidQueue::Dispatcher.new(concurrency_maintenance: false, recurring_tasks: updated_task).tap(&:start)
    wait_for_registered_processes(6, timeout: 1.second)

    assert_recurring_tasks configured_task.merge(updated_task)

    terminate_process(@pid)
    dispatcher1.stop
    dispatcher2.stop

    assert_recurring_tasks []
  end

  private
    def wait_for_jobs_to_be_enqueued(count, timeout: 1.second)
      wait_while_with_timeout(timeout) { SolidQueue::Job.count < count }
    end

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
