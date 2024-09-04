# frozen_string_literal: true

require "thor"

module SolidQueue
  class Cli < Thor
    class_option :config_file, type: :string, aliases: "-c", default: Configuration::DEFAULT_CONFIG_FILE_PATH, desc: "Path to config file"

    def self.exit_on_failure?
      true
    end

    desc :start, "Starts Solid Queue supervisor to dispatch and perform enqueued jobs. Default command."
    default_command :start

    def start
      SolidQueue::Supervisor.start(config_file: options["config_file"])
    end
  end
end
