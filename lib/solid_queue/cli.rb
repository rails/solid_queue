# frozen_string_literal: true

require "thor"

module SolidQueue
  class Cli < Thor
    class_option :config_file, type: :string, aliases: "-c", default: Configuration::DEFAULT_CONFIG_FILE_PATH, desc: "Path to config file"
    class_option :mode, type: :string, default: "fork", enum: %w[ fork async ], desc: "Whether to fork processes for workers and dispatchers (fork) or to run these in the same process as the supervisor (async)"

    def self.exit_on_failure?
      true
    end

    desc :start, "Starts Solid Queue supervisor to dispatch and perform enqueued jobs. Default command."
    default_command :start

    def start
      SolidQueue::Supervisor.start(mode: options["mode"], load_configuration_from: options["config_file"])
    end
  end
end
