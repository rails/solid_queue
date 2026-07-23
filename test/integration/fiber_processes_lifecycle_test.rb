# frozen_string_literal: true

require "test_helper"

class FiberProcessesLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = fork do
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      SolidQueue::Supervisor.start(skip_recurring: true, workers: [ { queues: :background, fibers: 3, polling_interval: 0.1 } ])
    end

    wait_for_registered_processes(2, timeout: 3.second)
    assert_registered_workers_for(:background, supervisor_pid: @pid)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)
  end

  test "process jobs in fibers in a forked worker" do
    worker = find_processes_registered_as("Worker").first
    assert_metadata worker, pool_type: "fiber", pool_size: 3

    6.times { |i| enqueue_store_result_job("job_#{i}") }

    wait_for_jobs_to_finish_for(3.seconds)

    assert_equal 6, skip_active_record_query_cache { JobResult.count }
    6.times { |i| assert_completed_job_results("job_#{i}", :background) }

    terminate_process(@pid)
    assert_clean_termination
  end

  test "term supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 1.second)

    signal_process(@pid, :TERM, wait: 0.3.second)
    wait_for_jobs_to_finish_for(3.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    wait_for_process_termination_with_timeout(@pid, timeout: 1.second)
    assert_clean_termination
  end

  test "quit supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    # long enough pause to make sure it doesn't finish
    pause = enqueue_store_result_job("pause", pause: 60.second)

    wait_while_with_timeout(1.second) { SolidQueue::ReadyExecution.count > 0 }

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
    assert_job_status(pause, :ready)
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

    def enqueue_store_result_job(value, queue_name = :background, **options)
      StoreResultJob.set(queue: queue_name).perform_later(value, **options)
    end

    def assert_completed_job_results(value, queue_name = :background, count = 1)
      actual = skip_active_record_query_cache {
        JobResult.where(queue_name: queue_name, status: "completed", value: value).count
      }
      assert_equal count, actual
    end

    def assert_started_job_result(value, queue_name = :background, count = 1)
      actual = skip_active_record_query_cache {
        JobResult.where(queue_name: queue_name, status: "started", value: value).count
      }
      assert_equal count, actual
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
