# frozen_string_literal: true

require "test_helper"

class AsyncProcessesLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork(mode: :async, workers: [ { queues: :background }, { queues: :default, threads: 5 } ])

    wait_for_registered_processes(3, timeout: 3.second)
    assert_registered_workers_for(:background, :default, supervisor_pid: @pid)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "enqueue jobs in multiple queues" do
    6.times { |i| enqueue_store_result_job("job_#{i}") }
    6.times { |i| enqueue_store_result_job("job_#{i}", :default) }

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal 12, JobResult.count
    6.times { |i| assert_completed_job_results("job_#{i}", :background) }
    6.times { |i| assert_completed_job_results("job_#{i}", :default) }

    terminate_process(@pid)
    assert_clean_termination
  end

  test "kill supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 3.second)

    signal_process(@pid, :KILL, wait: 0.2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)
    wait_for_registered_processes(1, timeout: 2.second)

    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # In async mode, killing the supervisor kills all threads too,
    # so we can't complete in-flight jobs
    assert_registered_supervisor
    assert_registered_workers_for(:background, :default, supervisor_pid: @pid)
    assert_started_job_result("pause")
    assert_claimed_jobs
  end

  test "term supervisor multiple times" do
    5.times do
      signal_process(@pid, :TERM, wait: 0.1.second)
    end

    sleep(1.second)
    assert_clean_termination
  end

  test "quit supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 1.second)

    wait_while_with_timeout(1.second) { SolidQueue::ReadyExecution.count > 0 }

    signal_process(@pid, :QUIT, wait: 0.4.second)
    wait_for_jobs_to_finish_for(2.seconds, except: pause)

    wait_while_with_timeout(2.seconds) { process_exists?(@pid) }
    assert_not process_exists?(@pid)

    # In async mode, QUIT calls exit! which terminates immediately without cleanup.
    # The in-flight job remains claimed and the process/workers remain registered.
    # A future supervisor will need to prune and fail these orphaned executions.
    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)
    assert_started_job_result("pause")
    assert_job_status(pause, :claimed)

    assert_registered_supervisor
    assert_registered_workers_for(:background, :default, supervisor_pid: @pid)
    assert_claimed_jobs
  end

  test "term supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 0.2.seconds)

    signal_process(@pid, :TERM, wait: 0.3.second)
    wait_for_jobs_to_finish_for(3.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    wait_for_process_termination_with_timeout(@pid, timeout: 1.second)
    assert_clean_termination
  end

  test "int supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 0.2.seconds)

    signal_process(@pid, :INT, wait: 0.3.second)
    wait_for_jobs_to_finish_for(2.second)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    wait_for_process_termination_with_timeout(@pid, timeout: 1.second)
    assert_clean_termination
  end

  test "term supervisor exceeding timeout while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: SolidQueue.shutdown_timeout + 10.second)

    wait_while_with_timeout(1.second) { SolidQueue::ReadyExecution.count > 1 }

    signal_process(@pid, :TERM, wait: 0.5.second)
    wait_for_jobs_to_finish_for(2.seconds, except: pause)

    # exit! exits with status 1 by default
    wait_for_process_termination_with_timeout(@pid, timeout: SolidQueue.shutdown_timeout + 5.seconds, exitstatus: 1)
    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # When timeout is exceeded, exit! is called without cleanup.
    # The in-flight job stays claimed and processes stay registered.
    # A future supervisor will need to prune and fail these orphaned executions.
    assert_started_job_result("pause")
    assert_job_status(pause, :claimed)

    assert_registered_supervisor
    assert find_processes_registered_as("Worker").any? { |w| w.metadata["queues"].include?("background") }
    assert_claimed_jobs
  end

  test "process some jobs that raise errors" do
    2.times { enqueue_store_result_job("no error", :background) }
    2.times { enqueue_store_result_job("no error", :default) }
    error1 = enqueue_store_result_job("error", :background, exception: ExpectedTestError)
    enqueue_store_result_job("no error", :background, pause: 0.03)
    error2 = enqueue_store_result_job("error", :background, exception: ExpectedTestError, pause: 0.05)
    2.times { enqueue_store_result_job("no error", :default, pause: 0.01) }
    error3 = enqueue_store_result_job("error", :default, exception: ExpectedTestError)

    wait_for_jobs_to_finish_for(2.second, except: [ error1, error2, error3 ])

    assert_completed_job_results("no error", :background, 3)
    assert_completed_job_results("no error", :default, 4)

    wait_while_with_timeout(1.second) { SolidQueue::FailedExecution.count < 3 }
    [ error1, error2, error3 ].each do |job|
      assert_job_status(job, :failed)
    end

    terminate_process(@pid)
    assert_clean_termination
  end


  private
    def assert_clean_termination
      wait_for_registered_processes 0, timeout: 0.2.second
      assert_no_registered_processes
      assert_no_claimed_jobs
      assert_not process_exists?(@pid)
    end

    def assert_registered_workers_for(*queues, supervisor_pid: nil)
      workers = find_processes_registered_as("Worker")
      registered_queues = workers.map { |process| process.metadata["queues"] }.compact
      assert_equal queues.map(&:to_s).sort, registered_queues.sort
      if supervisor_pid
        assert_equal [ supervisor_pid ], workers.map { |process| process.supervisor.pid }.uniq
      end
    end

    def assert_registered_supervisor
      processes = find_processes_registered_as("Supervisor(async)")
      assert_equal 1, processes.count
      assert_equal @pid, processes.first.pid
    end

    def assert_no_registered_workers
      assert_empty find_processes_registered_as("Worker").to_a
    end

    def enqueue_store_result_job(value, queue_name = :background, **options)
      StoreResultJob.set(queue: queue_name).perform_later(value, **options)
    end

    def assert_completed_job_results(value, queue_name = :background, count = 1)
      skip_active_record_query_cache do
        assert_equal count, JobResult.where(queue_name: queue_name, status: "completed", value: value).count
      end
    end

    def assert_started_job_result(value, queue_name = :background, count = 1)
      skip_active_record_query_cache do
        assert_equal count, JobResult.where(queue_name: queue_name, status: "started", value: value).count
      end
    end

    def assert_job_status(active_job, status)
      skip_active_record_query_cache do
        job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)
        assert job.public_send("#{status}?")
      end
    end
end
