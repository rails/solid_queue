# frozen_string_literal: true

require "test_helper"

class PumaPluginTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    FileUtils.mkdir_p Rails.root.join("tmp", "pids")

    Dir.chdir("test/dummy") do
      cmd = %w[
        bundle exec puma
          -b tcp://127.0.0.1:9222
          -C config/puma.rb
          -s
          config.ru
      ]

      @pid = fork do
        exec(*cmd)
      end
    end

    wait_for_registered_processes(4, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid, signal: :INT) if process_exists?(@pid)

    wait_for_registered_processes 0, timeout: 1.second

    JobResult.delete_all
  end

  test "perform jobs inside puma's process" do
    StoreResultJob.perform_later(:puma_plugin)

    wait_for_jobs_to_finish_for(1.second)
    assert_equal 1, JobResult.where(queue_name: :background, status: "completed", value: :puma_plugin).count
  end

  test "stop the queue on puma's restart" do
    signal_process(@pid, :SIGUSR2)
    # Ensure the restart finishes before we try to continue with the test
    wait_for_registered_processes(0, timeout: 3.second)
    wait_for_registered_processes(4, timeout: 3.second)

    StoreResultJob.perform_later(:puma_plugin)
    wait_for_jobs_to_finish_for(2.seconds)
    assert_equal 1, JobResult.where(queue_name: :background, status: "completed", value: :puma_plugin).count
  end

  test "stop puma when solid queue's supervisor dies" do
    supervisor = find_processes_registered_as("Supervisor").first

    signal_process(supervisor.pid, :KILL)
    wait_for_process_termination_with_timeout(@pid)

    assert_not process_exists?(@pid)
  end
end
