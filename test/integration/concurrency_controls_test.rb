# frozen_string_literal: true
require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    SolidQueue::Job.delete_all

    @result = JobResult.create!(queue_name: "default", status: "seq: ")

    default_worker = { queues: "default", polling_interval: 1, processes: 3, threads: 2 }
    @pid = run_supervisor_as_fork(load_configuration_from: { workers: [ default_worker ] })

    wait_for_registered_processes(4, timeout: 0.2.second) # 3 workers working the default queue + supervisor
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "run several conflicting jobs over the same record sequentially" do
    ("A".."F").each do |name|
      SequentialUpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds)
    end

    ("G".."K").each do |name|
      SequentialUpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(4.seconds)
    assert_no_pending_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "run several jobs over the same record limiting concurrency" do
    incr = 0
    # C is the last one to update the record
    # A: 0 to 0.5
    # B: 0 to 1.0
    # C: 0 to 1.5
    assert_no_difference -> { SolidQueue::BlockedExecution.count } do
      ("A".."C").each do |name|
        ThrottledUpdateResultJob.perform_later(@result, name: name, pause: (0.5 + incr).seconds)
        incr += 0.5
      end
    end

    sleep(0.01) # To ensure these aren't picked up before ABC
    # D to H: 0.51 to 0.76 (starting after A finishes, and in order, 5 * 0.05 = 0.25)
    # These would finish all before B and C
    assert_difference -> { SolidQueue::BlockedExecution.count }, +5 do
      ("D".."H").each do |name|
        ThrottledUpdateResultJob.perform_later(@result, name: name, pause: 0.05.seconds)
      end
    end

    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    # C would have started in the beginning, seeing the status empty, and would finish after
    # all other jobs, so it'll do the last update with only itself
    assert_stored_sequence(@result, [ "C" ])
  end

  private
    def assert_stored_sequence(result, sequence)
      expected = "seq: " + sequence.map { |name| "s#{name}c#{name}"}.join
      skip_active_record_query_cache do
        assert_equal expected, result.reload.status
      end
    end
end
