# frozen_string_literal: true

require "test_helper"

class RecurringTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork(mode: :all)
    # 1 supervisor + 2 workers + 1 dispatcher
    wait_for_registered_processes(4, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::Process.destroy_all
    SolidQueue::Job.destroy_all
    JobResult.delete_all
  end

  test "enqueue and process periodic tasks" do
    wait_for_jobs_to_be_enqueued(2, timeout: 2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    terminate_process(@pid)

    skip_active_record_query_cache do
      matching_jobs = SolidQueue::Job.all.select do |job|
        "periodic_store_result" == job.recurring_execution.task_key &&
        "StoreResultJob" == job.class_name
      end
      assert matching_jobs.count >= 2

      matching_results = JobResult.all.select do |result|
        "custom_status" == result.status &&
        "42" == result.value
      end
      assert matching_results.count >= 2
    end
  end

  test "job failures are reported via Rails error subscriber" do
    subscriber = ErrorBuffer.new
    with_error_subscriber(subscriber) do
      wait_for_jobs_to_be_enqueued(2, timeout: 2.seconds)
      wait_for_jobs_to_finish_for(2.seconds)

      terminate_process(@pid)

      skip_active_record_query_cache do
        matching_jobs = SolidQueue::Job.all.select do |job|
          "periodic_raise_exception" == job.recurring_execution.task_key &&
          "StoreResultJob" == job.class_name
        end
        assert matching_jobs.count >= 2

        matching_results = JobResult.all.select do |result|
          "started" == result.status &&
          "42" == result.value
        end
        assert matching_results.count >= 2
      end
    end

    assert subscriber.errors.count >= 2
    assert_equal "RuntimeError", subscriber.messages.first
  end

  private
    def wait_for_jobs_to_be_enqueued(count, timeout: 1.second)
      wait_while_with_timeout(timeout) { SolidQueue::Job.count < count }
    end

    def with_error_subscriber(subscriber)
      Rails.error.subscribe(subscriber)
      yield
    ensure
      Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
    end
end
