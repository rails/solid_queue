# frozen_string_literal: true
require "test_helper"

class PumaPluginTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    FileUtils.mkdir_p Rails.root.join("tmp", "pids")

    cmd = %w[
      bundle exec puma
        -b tcp://127.0.0.1:9222
        -C test/dummy/config/puma.rb
        --dir test/dummy
        -s
        config.ru
    ]

    @pid = fork do
      exec(*cmd)
    end

    wait_for_registered_processes(4, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid, signal: :INT)
    wait_for_registered_processes 0, timeout: 0.2.second

    JobResult.delete_all
  end

  test "perform jobs inside puma's process" do
    StoreResultJob.perform_later(:puma_plugin)

    wait_for_jobs_to_finish_for(1.second)
    assert_equal 1, JobResult.where(queue_name: :background, status: "completed", value: :puma_plugin).count
  end
end
