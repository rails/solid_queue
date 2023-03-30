require "test_helper"

class SupervisorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    FileUtils.mkdir_p Rails.application.root.join("tmp")
    @previous_pidfile = SolidQueue.supervisor_pidfile
    @pidfile = Rails.application.root.join("tmp/pidfile_#{SecureRandom.hex}.pid")
    SolidQueue.supervisor_pidfile = @pidfile
  end

  teardown do
    SolidQueue.supervisor_pidfile = @previous_pidfile
    File.delete(@pidfile) if File.exist?(@pidfile)
  end

  test "create and delete pidfile" do
    assert_not File.exist?(@pidfile)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(3)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)

    assert_not File.exist?(@pidfile)
  end

  test "abort if there's already a pidfile for a supervisor" do
    File.write(@pidfile, ::Process.pid.to_s)

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(3)

    assert File.exist?(@pidfile)
    assert_not_equal pid, File.read(@pidfile).strip.to_i

    wait_for_process_termination_with_timeout(pid, exitstatus: 1)
  end

  test "deletes previous pidfile if the owner is dead" do
    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(3)

    terminate_process(pid, signal: :KILL)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    pid = run_supervisor_as_fork(mode: :all)
    wait_for_registered_processes(3)

    assert File.exist?(@pidfile)
    assert_equal pid, File.read(@pidfile).strip.to_i

    terminate_process(pid)
  end

  private
    def run_supervisor_as_fork(**options)
      fork do
        SolidQueue::Supervisor.start(**options)
      end
    end

    def wait_for_registered_processes(count, timeout: 10.seconds)
      Timeout.timeout(timeout) do
        while SolidQueue::Process.count < count do
          sleep 0.25
        end
      end
    rescue Timeout::Error
    end

    def terminate_process(pid, timeout: 10, signal: :TERM)
      Process.kill(signal, pid)
      wait_for_process_termination_with_timeout(pid, timeout: timeout)
    end

    def wait_for_process_termination_with_timeout(pid, timeout: 10, exitstatus: 0)
      Timeout.timeout(timeout) do
        Process.waitpid(pid)
        assert exitstatus, $?.exitstatus
      end
    rescue Timeout::Error
      Process.kill(:KILL, pid)
      raise
    end
end
