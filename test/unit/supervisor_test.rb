require "test_helper"

class SupervisorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @previous_pidfile = SolidQueue.supervisor_pidfile
    @pidfile = Rails.application.root.join("tmp/pids/pidfile_#{SecureRandom.hex}.pid")
    SolidQueue.supervisor_pidfile = @pidfile
  end

  teardown do
    SolidQueue.supervisor_pidfile = @previous_pidfile
    File.delete(@pidfile) if File.exist?(@pidfile)

    SolidQueue::Process.destroy_all
  end

  test "start" do
    pid = run_supervisor_as_fork
    wait_for_registered_processes(4)

    assert_registered_supervisor(pid)
    assert_registered_workers(2, supervisor_pid: pid)
    assert_registered_dispatcher(supervisor_pid: pid)

    terminate_process(pid)

    assert_no_registered_processes
  end

  test "start with provided configuration" do
    config_as_hash = { workers: [], dispatchers: [ { batch_size: 100 } ] }
    pid = run_supervisor_as_fork(load_configuration_from: config_as_hash)
    wait_for_registered_processes(2) # supervisor + dispatcher

    assert_registered_supervisor(pid)
    assert_registered_workers(0)
    assert_registered_dispatcher(supervisor_pid: pid)

    terminate_process(pid)

    assert_no_registered_processes
  end

  test "create and delete pidfile" do
    assert_not File.exist?(@pidfile)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(4)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)

    assert_not File.exist?(@pidfile)
  end

  test "abort if there's already a pidfile for a supervisor" do
    FileUtils.mkdir_p(File.dirname(@pidfile))
    File.write(@pidfile, ::Process.pid.to_s)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(4)

    assert File.exist?(@pidfile)
    assert_not_equal pid, File.read(@pidfile).strip.to_i

    wait_for_process_termination_with_timeout(pid, exitstatus: 1)
  end

  test "delete previous pidfile if the owner is dead" do
    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(4)

    terminate_process(pid, signal: :KILL)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    wait_for_registered_processes(0)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(4)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)
  end

  test "release orphaned executions" do
    3.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
    process = SolidQueue::Process.register(kind: "Worker", pid: 42)

    SolidQueue::ReadyExecution.claim("*", 5, process.id)

    assert_equal 3, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::ReadyExecution.count

    assert_equal [ process.id ], SolidQueue::ClaimedExecution.last(3).pluck(:process_id).uniq

    # Simnulate orphaned executions by just wiping the claiming process
    process.delete

    pid = run_supervisor_as_fork
    wait_for_registered_processes(4)
    assert_registered_supervisor(pid)

    terminate_process(pid)

    skip_active_record_query_cache do
      assert_equal 0, SolidQueue::ClaimedExecution.count
      assert_equal 3, SolidQueue::ReadyExecution.count
    end
  end

  private
    def assert_registered_workers(count, supervisor_pid: nil, **metadata)
      skip_active_record_query_cache do
        workers = find_processes_registered_as("Worker")
        assert_equal count, workers.count

        workers.each do |process|
          assert_equal supervisor_pid, process.supervisor.pid
          assert metadata < process.metadata.symbolize_keys
        end
      end
    end

    def assert_registered_dispatcher(supervisor_pid:, **metadata)
      skip_active_record_query_cache do
        processes = find_processes_registered_as("Dispatcher")
        assert_equal 1, processes.count
        assert_equal supervisor_pid, processes.first.supervisor.pid
        assert metadata < processes.first.metadata.symbolize_keys
      end
    end

    def assert_registered_supervisor(pid)
      skip_active_record_query_cache do
        processes = find_processes_registered_as("Supervisor")
        assert_equal 1, processes.count
        assert_nil processes.first.supervisor
        assert_equal pid, processes.first.pid
      end
    end
end
