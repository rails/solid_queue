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
  end

  test "start in work mode (default)" do
    pid = run_supervisor_as_fork
    wait_for_registered_processes(0.3)
    assert_registered_workers(2, supervisor_pid: pid)

    terminate_process(pid)

    assert_no_registered_processes
  end

  test "start in schedule mode" do
    pid = run_supervisor_as_fork(mode: :schedule)
    wait_for_registered_processes(0.3)
    assert_registered_scheduler(supervisor_pid: pid)

    terminate_process(pid)

    assert_no_registered_processes
  end

  test "create and delete pidfile" do
    assert_not File.exist?(@pidfile)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(0.3)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)

    assert_not File.exist?(@pidfile)
  end

  test "abort if there's already a pidfile for a supervisor" do
    FileUtils.mkdir_p(File.dirname(@pidfile))
    File.write(@pidfile, ::Process.pid.to_s)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(0.3)

    assert File.exist?(@pidfile)
    assert_not_equal pid, File.read(@pidfile).strip.to_i

    wait_for_process_termination_with_timeout(pid, exitstatus: 1)
  end

  test "deletes previous pidfile if the owner is dead" do
    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(0.3)

    terminate_process(pid, signal: :KILL)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(0.3)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)
  end

  private
    def assert_registered_workers(count, **metadata)
      skip_active_record_query_cache do
        assert_equal count, SolidQueue::Process.count

        SolidQueue::Process.all.each do |process|
          assert_equal "Worker", process.metadata["kind"]
          assert metadata < process.metadata.symbolize_keys
        end
      end
    end

    def assert_registered_scheduler(**metadata)
      skip_active_record_query_cache do
        assert_equal 1, SolidQueue::Process.count
        scheduler = SolidQueue::Process.first

        assert_equal "Scheduler", scheduler.metadata["kind"]
        assert metadata < scheduler.metadata.symbolize_keys
      end
    end
end
