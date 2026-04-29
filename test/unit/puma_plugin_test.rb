# frozen_string_literal: true

require "test_helper"
require "puma/plugin/solid_queue"

class PumaPluginTest < ActiveSupport::TestCase
  class ClosedTerminalLogWriter
    def log(...)
      raise Errno::EIO
    end
  end

  test "monitor still stops the process when shutdown logging fails" do
    plugin = Puma::Plugins.find("solid_queue").new
    plugin.instance_variable_set(:@log_writer, ClosedTerminalLogWriter.new)

    plugin.stubs(:puma_dead?).returns(true)
    Process.expects(:kill).with(:INT, Process.pid)

    plugin.send(:monitor, :puma_dead?, "Detected Puma has gone away, stopping Solid Queue...")
  end
end
