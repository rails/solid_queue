# frozen_string_literal: true
require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    SolidQueue::Job.delete_all

    @result = JobResult.create!(queue_name: "default", status: "seq: ")

    default_worker = { queues: "default", polling_interval: 1, processes: 3 }
    @pid = run_supervisor_as_fork(load_configuration_from: { workers: [ default_worker ] })

    wait_for_registered_processes(4, timeout: 0.2.second) # 3 workers working the default queue + supervisor
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "run several conflicting jobs and prevent overlapping" do
    ("A".."F").each do |name|
      UpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds)
    end

    ("G".."K").each do |name|
      UpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(4.seconds)
    assert_stored_sequence @result, ("A".."K").to_a
  end

  private
    def assert_stored_sequence(result, sequence)
      expected = "seq: " + sequence.map { |name| "s#{name}c#{name}"}.join
      skip_active_record_query_cache do
        assert_equal expected, result.reload.status
      end
    end
end
