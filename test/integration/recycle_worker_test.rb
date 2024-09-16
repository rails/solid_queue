# frozen_string_literal: true

require "test_helper"
require "thread"

class RecycleWorkerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  attr_accessor :pid

  def setup
    @pid = nil
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "recycle_on_oom set via worker config" do
    @pid, _count = start_solid_queue(default_worker, calc_memory_usage_oom)

    SolidQueue::Process.where(kind: "Worker").each do |worker|
      assert worker.metadata.has_key?("recycle_on_oom"), "Worker not configured for recycle_on_oom #{worker.id} #{worker.metadata}\n"
    end
  end

  test "recycle_on_oom via worker config per worker" do
    workers = [
      { queues: "with", polling_interval: 0.1, processes: 3, threads: 2, recycle_on_oom: 1 },
      { queues: "without", polling_interval: 0.1, processes: 3, threads: 2 }
    ]

    @pid, _count = start_solid_queue(workers, calc_memory_usage_oom)

    process_with, process_without = SolidQueue::Process.where(kind: "Worker").partition { _1.metadata["queues"] == "with" }

    assert process_with.all? { _1.metadata.has_key?("recycle_on_oom") }, "Worker unexpectedly configured without recycle_on_oom"
    assert process_without.none? { _1.metadata.has_key?("recycle_on_oom") }, "Worker unexpectedly configured with recycle_on_oom"
  end

  test "recycle_on_oom is an optional config parameter" do
    worker_without_recycle = default_worker.tap { _1.delete(:recycle_on_oom) }
    @pid, _count = start_solid_queue(worker_without_recycle, calc_memory_usage_oom)

    SolidQueue::Process.where(kind: "Worker").each do |worker|
      assert_not worker.metadata.has_key?("recycle_on_oom"), "Worker configured for recycle_on_oom #{worker.id} #{worker.metadata}\n"
    end
  end

  test "recycle_on_oom is off globally without setting calc_memory_usage (default)" do
    @pid, _count = start_solid_queue(default_worker, calc_memory_usage_off)

    SolidQueue::Process.where(kind: "Worker").each do |worker|
      assert_not worker.metadata.has_key?("recycle_on_oom"), "Worker configured for recycle_on_oom #{worker.id} #{worker.metadata}\n"
    end
  end

  test "Workers don't recycle unless configured" do
    @pid, count = start_solid_queue(default_worker, calc_memory_usage_off) # this turns recycle OFF

    _before_id, before_pid = worker_process
    assert_not before_pid.nil?, "Before PID nil"

    jobs = 0.upto(5).map { RecycleJob.new }
    ActiveJob.perform_all_later(jobs)

    wait_for_jobs_to_finish_for(6.seconds)
    assert_no_unfinished_jobs
    wait_for_registered_processes(count, timeout: 1.second)

    _before_id, after_pid = worker_process
    assert_not after_pid.nil?, "After PID nil"

    assert before_pid == after_pid, "Worker unexpectedly recycled"
  end

  test "Worker recycles on OOM condition" do
    @pid, count = start_solid_queue(default_worker, calc_memory_usage_oom)

    before_id, before_pid = worker_process
    assert_not before_pid.nil?, "Before PID nil"

    jobs = 0.upto(5).map { RecycleJob.new }
    ActiveJob.perform_all_later(jobs)

    wait_for_jobs_to_finish_for(10.seconds)
    assert_no_unfinished_jobs
    wait_for_registered_processes(count, timeout: 1.second)

    after_id, after_pid = worker_process

    assert_not after_pid.nil?, "After PID nil"
    assert before_pid != after_pid, "Worker didn't recycled"
  end

  test "Worker don't recycle without OOM condition" do
    @pid, count = start_solid_queue(default_worker, calc_memory_usage_not_oom)

    before_id, before_pid = worker_process
    assert_not before_pid.nil?, "Before PID nil"

    jobs = 0.upto(5).map { RecycleJob.new }
    ActiveJob.perform_all_later(jobs)

    wait_for_jobs_to_finish_for(10.seconds)
    assert_no_unfinished_jobs
    wait_for_registered_processes(count, timeout: 1.second)

    after_id, after_pid = worker_process

    assert_not after_pid.nil?, "After PID nil"
    assert before_pid == after_pid, "Worker unexpectedly recycled PID"
    assert before_id == after_id, "Worker unexpectedly created new Process row"
  end

  test "Jobs on threads finish even when worker recycles on OOM" do
    workers = { queues: %w[fast slow], polling_interval: 0.1, processes: 1, threads: 2, recycle_on_oom: 1 }
    @pid, count = start_solid_queue(workers, calc_memory_usage_oom)

    before_id, before_pid = worker_process
    assert_not before_pid.nil?, "Before PID nil"

    RecycleJob.set(queue: "slow").perform_later(2)
    RecycleJob.set(queue: "fast").perform_later(0)
    RecycleJob.set(queue: "slow").perform_later(2)
    RecycleJob.set(queue: "fast").perform_later(0)

    wait_for_jobs_to_finish_for(10.seconds)
    assert_no_unfinished_jobs
    wait_for_registered_processes(count, timeout: 1.second)

    after_id, after_pid = worker_process

    assert_not after_pid.nil?, "After PID nil"
    assert before_pid != after_pid, "Worker didn't create new PID"
    assert before_id != after_id, "Worker did not created new Process row"
  end

  test "Jobs that hold locks are released on OOM recycle " do
    @pid, count = start_solid_queue(default_worker, calc_memory_usage_oom)

    before_id, before_pid = worker_process
    assert_not before_pid.nil?, "Before PID nil"

    jobs = 0.upto(9).map { RecycleJob.new }
    ActiveJob.perform_all_later(jobs)

    wait_for_jobs_to_finish_for(15.seconds)
    assert_no_unfinished_jobs
    wait_for_registered_processes(count, timeout: 1.second)

    after_id, after_pid = worker_process

    assert_not after_pid.nil?, "After PID nil"
    assert before_pid != after_pid, "Worker didn't change PID"
  end

  private
    def start_solid_queue(workers, calc_memory_usage)
      w = workers.is_a?(Array) ? workers : [ workers ]

      pid = fork do
        SolidQueue.calc_memory_usage = calc_memory_usage
        SolidQueue.shutdown_timeout = 1.second

        SolidQueue::Supervisor.start(workers: w, dispatchers: default_dispatcher, skip_recurring: true)
      end

      expected_process_count = w.sum { _1.fetch(:processes, 1) } + 2 # supervisor + dispatcher
      wait_for_registered_processes(expected_process_count, timeout: 0.5.second) # 3 workers working the default queue + dispatcher + supervisor

      [ pid, expected_process_count ]
    end

    def worker_process
      SolidQueue::Process.find_by(kind: "Worker")&.slice(:id, :pid)&.values
    end

    def calc_memory_usage_oom
      ->(_pid) { 2 }
    end

    def calc_memory_usage_not_oom
      ->(_pid) { 0 }
    end

    def calc_memory_usage_off
      nil
    end

    def default_dispatcher
      [ { polling_interval: 0.1, batch_size: 100, concurrency_maintenance_interval: 600 } ]
    end

    def default_worker
      { queues: "default", polling_interval: 0.1, processes: 3, threads: 1, recycle_on_oom: 1 }
    end
end
