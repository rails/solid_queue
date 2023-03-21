# frozen_string_literal: true

require "test_helper"

class ProcessLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork

    wait_for_registered_processes(3, timeout: 1.second)
    assert_registered_processes_for(:background, :default)
  end

  teardown do
    terminate_supervisor if process_exists?(@pid)
  end

  test "enqueue jobs in multiple queues" do
    6.times.map { |i| enqueue_store_result_job("job_#{i}") }
    6.times.map { |i| enqueue_store_result_job("job_#{i}", :default) }

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal 12, JobResult.count
    6.times { |i| assert_completed_job_results("job_#{i}", :background) }
    6.times { |i| assert_completed_job_results("job_#{i}", :default) }

    terminate_supervisor
    assert_clean_termination
  end

  test "kill supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :KILL, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # Running worker finish with jobs in progress and terminate orderly
    assert_completed_job_results("pause")
    assert_job_status(pause, :finished)

    assert_clean_termination
  end

  test "quit supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :QUIT, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_not process_exists?(@pid)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # This job was left claimed as the worker was shutdown without
    # a chance to terminate orderly
    assert_started_job_result("pause")
    assert_job_status(pause, :claimed)

    # Processes didn't have a chance to deregister either
    assert_registered_processes_for(:background, :default)
  end

  test "term supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :TERM, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    assert_clean_termination
  end

  test "int supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :INT, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    assert_clean_termination
  end

  test "term supervisor exceeding timeout while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: SolidQueue.shutdown_timeout + 1.second)

    signal_fork(@pid, :TERM, wait: 1.second)
    wait_for_jobs_to_finish_for(SolidQueue.shutdown_timeout + 1.second)

    assert_completed_job_results("no pause")
    assert_job_status(no_pause, :finished)

    # This job was left claimed as the worker was shutdown without
    # a chance to terminate orderly
    assert_started_job_result("pause")
    assert_job_status(pause, :claimed)

    # The process running the long job couldn't deregister, the other did
    assert_registered_processes_for(:background)
  end

  test "process some jobs that raise errors" do
    enqueue_store_result_job("no error", :background, 2)
    enqueue_store_result_job("no error", :default, 2)
    error1 = enqueue_store_result_job("error", :background, 1, exception: RuntimeError)
    enqueue_store_result_job("no error", :background, 1, pause: 0.3)
    error2 = enqueue_store_result_job("error", :background, 1, exception: RuntimeError, pause: 0.5)
    enqueue_store_result_job("no error", :default, 2, pause: 0.1)
    error3 = enqueue_store_result_job("error", :default, 1, exception: RuntimeError)

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no error", :background, 3)
    assert_completed_job_results("no error", :default, 4)

    assert_failures 3
    [ error1, error2, error3 ].each do |job|
      assert_job_status(job, :failed)
    end

    terminate_supervisor
    assert_clean_termination
  end

  test "process a job that exits" do
    enqueue_store_result_job("no exit", :background, 2)
    enqueue_store_result_job("no exit", :default, 2)
    enqueue_store_result_job("paused no exit", :default, 1, pause: 0.5)
    exit_job = enqueue_store_result_job("exit", :background, 1, exit: true, pause: 0.2)
    pause_job = enqueue_store_result_job("exit", :background, 1, pause: 0.3)
    enqueue_store_result_job("no exit", :background, 2)

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no exit", :default, 2)
    assert_completed_job_results("no exit", :background, 4)
    assert_completed_job_results("paused no exit", :default, 1)

    # The background worker exits because of the exit job,
    # leaving the pause job claimed
    [ exit_job, pause_job ].each do |job|
      assert_job_status(job, :claimed)
    end

    assert process_exists?(@pid)

    terminate_supervisor
    # TODO: change this to clean termination when replacing a worker also deregisters its process ID
    assert_registered_processes_for(:background)
  end

  private
    def run_supervisor_as_fork
      fork do
        SolidQueue::Supervisor.start
      end
    end

    def terminate_supervisor
      terminate_process(@pid)
    end

    def terminate_registered_processes
      uncached do
        SolidQueue::Process.find_each do |process|
          terminate_process(process.metadata["pid"], from_parent: false)
        end
      end
    end

    def assert_clean_termination
      assert_no_registered_processes
      assert_no_claimed_jobs
    end

    def terminate_process(pid, from_parent: true)
      signal_fork(pid, :TERM)
      wait_for_process_with_timeout(pid, from_parent: from_parent)
    end

    def signal_fork(pid, signal, wait: nil)
      Thread.new do
        sleep(wait) if wait
        Process.kill(signal, pid)
      end
    end

    def wait_for_process_with_timeout(pid, timeout: 10, from_parent: true)
      Timeout.timeout(timeout) do
        if from_parent
          Process.waitpid(pid)
          assert 0, $?.exitstatus
        else
          loop do
            break unless process_exists?(pid)
            sleep(0.1)
          end
        end
      end
    rescue Timeout::Error
      Process.kill(:KILL, pid)
      raise
    end

    def process_exists?(pid)
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    end

    def wait_for_registered_processes(count, timeout: 10.seconds)
      Timeout.timeout(timeout) do
        while SolidQueue::Process.count < count do
          sleep 0.25
        end
      end
    rescue Timeout::Error
    end

    def assert_registered_processes_for(*queues)
      uncached do
        registered_queues = SolidQueue::Process.all.map { |process| process.metadata["queue"] }.compact
        assert_equal queues.map(&:to_s).sort, registered_queues.sort
      end
    end

    def assert_no_registered_processes
      uncached do
        assert SolidQueue::Process.none?
      end
    end

    def enqueue_store_result_job(value, queue_name = :background, count = 1, **options)
      count.times.collect { StoreResultJob.set(queue: queue_name).perform_later(value, **options) }.then do |jobs|
        jobs.one? ? jobs.first : jobs
      end
    end

    def assert_completed_job_results(value, queue_name = :background, count = 1)
      assert_equal count, JobResult.where(queue_name: queue_name, status: "completed", value: value).count
    end

    def assert_started_job_result(value, queue_name = :background, count = 1)
      assert_equal count, JobResult.where(queue_name: queue_name, status: "started", value: value).count
    end

    def assert_job_status(active_job, status)
      # Make sure we skip AR query cache. Otherwise the queries done here
      # might be cached and since we haven't done any non-SELECT queries
      # after they were cached on the connection used in the test, the cache
      # will still apply, even though the data returned by the cached queries
      # might have been deleted in the forked processes.
      uncached do
        job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)
        assert job.public_send("#{status}?")
      end
    end

    def assert_no_claimed_jobs
      assert SolidQueue::ClaimedExecution.none?
    end

    def assert_failures(count)
      assert_equal count, SolidQueue::FailedExecution.count
    end

    def uncached(&block)
      # Make sure we skip AR query cache. Otherwise the queries done here
      # might be cached and since we haven't done any non-SELECT queries
      # after they were cached on the connection used in the test, the cache
      # will still apply, even though the data returned by the cached queries
      # might have been updated, created or deleted in the forked processes.
      ActiveRecord::Base.uncached(&block)
    end
end
