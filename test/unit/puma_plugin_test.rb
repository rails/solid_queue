# frozen_string_literal: true

require "test_helper"
require "puma/plugin/solid_queue"

class PumaPluginTest < ActiveSupport::TestCase
  class ClosedOutputLogWriter
    def initialize(error)
      @error = error
    end

    def log(...)
      raise @error
    end
  end

  [ Errno::EIO, Errno::EPIPE, Errno::EBADF ].each do |error|
    test "monitor still stops the process when shutdown logging fails with #{error}" do
      plugin = Puma::Plugins.find("solid_queue").new
      plugin.instance_variable_set(:@log_writer, ClosedOutputLogWriter.new(error))

      plugin.stubs(:puma_dead?).returns(true)
      Process.expects(:kill).with(:INT, Process.pid)

      plugin.send(:monitor, :puma_dead?, "Detected Puma has gone away, stopping Solid Queue...")
    end
  end
end
