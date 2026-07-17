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

  test "check exits 0 and prints OK message for a valid configuration" do
    out, err = capture_io do
      assert_nothing_raised { SolidQueue::Cli.start([ "check", "--skip-recurring" ]) }
    end

    assert_match "Solid Queue configuration is valid.", out
    assert_empty err
  end

  test "check exits 1 and prints invalid recurring task errors" do
    out, err, exit_status = capture_check_run(
      "--recurring_schedule_file", config_file_path(:recurring_with_invalid).to_s
    )

    assert_equal 1, exit_status
    assert_match "Invalid Solid Queue configuration", err
    assert_match "periodic_invalid_class", err
    assert_match "periodic_incorrect_schedule", err
    assert_empty out
  end

  private
    def configuration_from_cli(**cli_options)
      cli = SolidQueue::Cli.new([], cli_options)
      options = cli.options.symbolize_keys.compact

      SolidQueue::Configuration.new(**options)
    end

    # capture_io re-raises SystemExit before returning the captured strings, so we
    # swallow it inside the block and return its status alongside the captured IO.
    def capture_check_run(*args)
      status = nil
      out, err = capture_io do
        begin
          SolidQueue::Cli.start([ "check", *args ])
        rescue SystemExit => e
          status = e.status
        end
      end
      [ out, err, status ]
    end
end
