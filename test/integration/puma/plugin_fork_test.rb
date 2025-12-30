# frozen_string_literal: true

require "test_helper"
require_relative "plugin_testing"

class PluginForkTest < ActiveSupport::TestCase
  include PluginTesting

  test "stop puma when solid queue's supervisor dies" do
    supervisor = find_processes_registered_as("Supervisor(fork)").first

    signal_process(supervisor.pid, :KILL)
    wait_for_process_termination_with_timeout(@pid)

    assert_not process_exists?(@pid)

    # When the supervisor is KILLed, the forked processes become orphans.
    # Clean them up manually.
    SolidQueue::Process.all.each do |process|
      signal_process(process.pid, :KILL) if process_exists?(process.pid)
    end

    wait_for_registered_processes 0, timeout: 3.second
  end

  private
    def solid_queue_mode
      :fork
    end
end
