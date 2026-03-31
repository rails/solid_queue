# frozen_string_literal: true

require "test_helper"
require "solid_queue/cli"

class CliTest < ActiveSupport::TestCase
  test "mode defaults to fork when no env var or option" do
    with_env("SOLID_QUEUE_SUPERVISOR_MODE" => nil) do
      config = configuration_from_cli

      assert config.mode.fork?
    end
  end

  test "mode respects SOLID_QUEUE_SUPERVISOR_MODE env var" do
    with_env("SOLID_QUEUE_SUPERVISOR_MODE" => "async") do
      config = configuration_from_cli

      assert config.mode.async?
    end
  end

  test "mode option overrides env var" do
    with_env("SOLID_QUEUE_SUPERVISOR_MODE" => "async") do
      config = configuration_from_cli(mode: "fork")

      assert config.mode.fork?
    end
  end

  test "mode option works without env var" do
    with_env("SOLID_QUEUE_SUPERVISOR_MODE" => nil) do
      config = configuration_from_cli(mode: "async")

      assert config.mode.async?
    end
  end

  private
    def configuration_from_cli(**cli_options)
      cli = SolidQueue::Cli.new([], cli_options)
      options = cli.options.symbolize_keys.compact

      SolidQueue::Configuration.new(**options)
    end
end
