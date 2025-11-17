# frozen_string_literal: true

require "test_helper"

class RecurringTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_recurring_supervisor
  end

  teardown do
    terminate_gracefully(@pid)
  end

  test "enqueue and process periodic tasks" do
    wait_for_jobs_to_be_enqueued(2, timeout: 2.5.seconds)
    wait_for_jobs_to_finish_for(2.5.seconds)

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

    assert_recurring_tasks configured_task
    task = SolidQueue::RecurringTask.find_by(key: "periodic_store_result")
    task.update!(class_name: "StoreResultJob", schedule: "every minute", arguments: [ 42 ])

    terminate_gracefully(@pid)

    @pid = run_recurring_supervisor

    assert_recurring_tasks configured_task

    another_task = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: [ 42 ] } }
    scheduler1 = SolidQueue::Scheduler.new(recurring_tasks: another_task).tap(&:start)
    wait_for_registered_processes(6, timeout: 1.second)

    assert_recurring_tasks another_task

    updated_task = { example_task: { class: "AddToBufferJob", schedule: "every minute" } }
    scheduler2 = SolidQueue::Scheduler.new(recurring_tasks: updated_task).tap(&:start)
    wait_for_registered_processes(7, timeout: 1.second)

    assert_recurring_tasks updated_task

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

    def run_recurring_supervisor
      pid = run_supervisor_as_fork(skip_recurring: false)
      wait_for_registered_processes(5, timeout: 3.seconds) # 1 supervisor + 2 workers + 1 dispatcher + 1 scheduler
      sleep 1.second # Wait for concurrency schedule loading after process registration
      pid
    end

    def terminate_gracefully(pid)
      return if pid.nil? || !process_exists?(pid)

      terminate_process(pid)
      wait_for_registered_processes(0, timeout: SolidQueue.shutdown_timeout)
    end
end
