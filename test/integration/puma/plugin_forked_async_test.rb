# frozen_string_literal: true

require "test_helper"
require_relative "plugin_testing"

class PluginForkedAsyncTest < ActiveSupport::TestCase
  include PluginTesting

  test "run the supervisor and its threads in a single process forked from puma" do
    supervisor = find_processes_registered_as("Supervisor(async)").first

    assert_not_equal @pid, supervisor.pid
    assert_equal [ supervisor.pid ], SolidQueue::Process.pluck(:pid).uniq
  end

  test "stop puma when solid queue's supervisor dies" do
    supervisor = find_processes_registered_as("Supervisor(async)").first

    signal_process(supervisor.pid, :KILL)
    wait_for_process_termination_with_timeout(@pid)

    assert_not process_exists?(@pid)

    # The killed supervisor couldn't deregister itself and its threads
    SolidQueue::Process.destroy_all
  end

  test "finish in-flight jobs when puma stops" do
    active_job = StoreResultJob.perform_later(:in_flight, pause: 1.second)
    job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
    wait_while_with_timeout(5.seconds) { skip_active_record_query_cache { job.reload.claimed_execution.nil? } }

    terminate_process(@pid, signal: :TERM)

    skip_active_record_query_cache do
      assert_equal 1, JobResult.where(value: :in_flight, status: "completed").count
      assert job.reload.finished?
      assert_nil job.ready_execution
    end
  end

  private
    def solid_queue_mode
      :forked_async
    end
end
