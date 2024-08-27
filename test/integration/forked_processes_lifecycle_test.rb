# frozen_string_literal: true

require "test_helper"

class ForkedProcessesLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    config_as_hash = { workers: [ { queues: :background }, { queues: :default, threads: 5 } ], dispatchers: [] }
    @pid = run_supervisor_as_fork(load_configuration_from: config_as_hash)

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
    pause = enqueue_store_result_job("pause", pause: 0.2.seconds)

    signal_process(@pid, :KILL, wait: 0.15.seconds)
    wait_for_jobs_to_finish_for(2.seconds)
    wait_for_registered_processes(1, timeout: 3.second)

    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # Running worker finish with jobs in progress and terminate orderly
    assert_completed_job_results("pause")
    assert_job_status(pause, :finished)

    # Termination is almost clean, but the supervisor remains
    assert_registered_supervisor_with(@pid)
    assert_no_registered_workers
    assert_no_claimed_jobs
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

    signal_process(@pid, :QUIT, wait: 0.4.second)
    wait_for_jobs_to_finish_for(2.seconds, except: pause)

    wait_while_with_timeout(2.seconds) { process_exists?(@pid) }
    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    assert_started_job_result("pause")
    # Workers were shutdown without a chance to terminate orderly, but
    # since they're linked to the supervisor, the supervisor deregistering
    # also deregistered them and released claimed jobs
    assert_clean_termination
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

    signal_process(@pid, :TERM, wait: 0.5.second)

    sleep(SolidQueue.shutdown_timeout + 0.5.second)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # This job was left claimed as the worker was shutdown without
    # a chance to terminate orderly
    assert_started_job_result("pause")
    assert_job_status(pause, :claimed)

    # The process running the long job couldn't deregister, the other did
    assert_registered_workers_for(:background)

    # Now wait until the supervisor finishes for real, which will complete the cleanup
    wait_for_process_termination_with_timeout(@pid, timeout: 1.second)
    assert_clean_termination
  end

  test "process some jobs that raise errors" do
    2.times { enqueue_store_result_job("no error", :background) }
    2.times { enqueue_store_result_job("no error", :default) }
    error1 = enqueue_store_result_job("error", :background, exception: RuntimeError)
    enqueue_store_result_job("no error", :background, pause: 0.03)
    error2 = enqueue_store_result_job("error", :background, exception: RuntimeError, pause: 0.05)
    2.times { enqueue_store_result_job("no error", :default, pause: 0.01) }
    error3 = enqueue_store_result_job("error", :default, exception: RuntimeError)

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

  test "process a job that exits" do
    2.times do
      enqueue_store_result_job("no exit", :background)
      enqueue_store_result_job("no exit", :default)
    end
    enqueue_store_result_job("paused no exit", :default, pause: 0.5)
    exit_job = enqueue_store_result_job("exit", :background, exit: true, pause: 0.2)
    pause_job = enqueue_store_result_job("exit", :background, pause: 0.3)

    2.times { enqueue_store_result_job("no exit", :background) }

    wait_for_jobs_to_finish_for(3.seconds, except: [ exit_job, pause_job ])

    assert_completed_job_results("no exit", :default, 2)
    assert_completed_job_results("no exit", :background, 4)
    assert_completed_job_results("paused no exit", :default, 1)

    # The background worker exits because of the exit job,
    # leaving the pause job claimed
    [ exit_job, pause_job ].each do |job|
      assert_job_status(job, :claimed)
    end

    assert process_exists?(@pid)
    terminate_process(@pid)

    # Since the worker exited abnormally, the jobs it had claimed would be failed now
    [ exit_job, pause_job ].each do |job|
      assert_job_status(job, :failed)
    end

    assert_clean_termination
  end

  test "terminate worker individually" do
    enqueue_store_result_job("pause", pause: 0.5.seconds)
    enqueue_store_result_job("pause", :default, pause: 0.5.seconds)

    worker = find_processes_registered_as("Worker").first

    signal_process(worker.pid, :TERM, wait: 0.1.second)

    # Worker is gone
    wait_for_registered_processes(2, timeout: 3.second)
    assert_nil SolidQueue::Process.find_by(id: worker.id)

    # Jobs were completed
    wait_for_jobs_to_finish_for(1.second)
    assert_completed_job_results("pause", :background)
    assert_completed_job_results("pause", :default)

    # And there's a new worker that has been registered for that queue:
    wait_for_registered_processes(3, timeout: 3.second)
    assert_registered_workers_for(:background, :default, supervisor_pid: @pid)

    # And they can process jobs just fine
    enqueue_store_result_job("no_pause")
    enqueue_store_result_job("no_pause", :default)
    wait_for_jobs_to_finish_for(1.second)

    assert_completed_job_results("no_pause", :background)
    assert_completed_job_results("no_pause", :default)

    terminate_process(@pid)
    assert_clean_termination
  end

  test "kill worker individually" do
    killed_pause = enqueue_store_result_job("killed_pause", pause: 1.second)
    enqueue_store_result_job("pause", :default, pause: 0.5.seconds)

    worker = find_processes_registered_as("Worker").detect { |process| process.metadata["queues"].include? "background" }
    signal_process(worker.pid, :KILL, wait: 0.5.seconds)

    # Worker didn't have time to clean up or finish the work
    sleep(0.5.second)
    assert SolidQueue::Process.exists?(id: worker.id)

    # And there's a new worker that has been registered for the background queue
    wait_for_registered_processes(4, timeout: 5.second)

    # The job in the background queue would be failed by the supervisor
    # when it replaced the killed worker
    assert_started_job_result("killed_pause")
    assert_job_status(killed_pause, :failed)
    # The other one could finish
    assert_completed_job_results("pause", :default)

    # The two current workers can process jobs just fine
    enqueue_store_result_job("no_pause")
    enqueue_store_result_job("no_pause", :default)
    sleep(2.seconds)

    assert_completed_job_results("no_pause", :background)
    assert_completed_job_results("no_pause", :default)

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

    def assert_registered_supervisor_with(pid)
      processes = find_processes_registered_as("Supervisor(fork)")
      assert_equal 1, processes.count
      assert_equal pid, processes.first.pid
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
      # Make sure we skip AR query cache. Otherwise the queries done here
      # might be cached and since we haven't done any non-SELECT queries
      # after they were cached on the connection used in the test, the cache
      # will still apply, even though the data returned by the cached queries
      # might have been deleted in the forked processes.
      skip_active_record_query_cache do
        job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)
        assert job.public_send("#{status}?")
      end
    end
end
