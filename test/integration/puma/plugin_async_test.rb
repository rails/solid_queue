# frozen_string_literal: true

require "test_helper"
require_relative "plugin_testing"

class PluginAsyncTest < ActiveSupport::TestCase
  include PluginTesting

  private
    def solid_queue_mode
      :async
    end
end
