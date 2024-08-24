# frozen_string_literal: true

module SolidQueue
  class Configuration
    class Process < Struct.new(:kind, :attributes)
      def instantiate
        "SolidQueue::#{kind.to_s.titleize}".safe_constantize.new(**attributes)
      end
    end

    WORKER_DEFAULTS = {
      queues: "*",
      threads: 3,
      processes: 1,
      polling_interval: 0.1
    }

    DISPATCHER_DEFAULTS = {
      batch_size: 500,
      polling_interval: 1,
      concurrency_maintenance: true,
      concurrency_maintenance_interval: 600,
      recurring_tasks: []
    }

    DEFAULT_CONFIG = {
      workers: [ WORKER_DEFAULTS ],
      dispatchers: [ DISPATCHER_DEFAULTS ]
    }

    def initialize(mode: :fork, load_from: nil)
      @mode = mode.to_s.inquiry
      @raw_config = config_from(load_from)
    end

    def configured_processes
      dispatchers + workers
    end

    def max_number_of_threads
      # At most "threads" in each worker + 1 thread for the worker + 1 thread for the heartbeat task
      workers_options.map { |options| options[:threads] }.max + 2
    end

    private
      attr_reader :raw_config, :mode

      DEFAULT_CONFIG_FILE_PATH = "config/solid_queue.yml"

      def workers
        workers_options.flat_map do |worker_options|
          processes = if mode.fork?
            worker_options.fetch(:processes, WORKER_DEFAULTS[:processes])
          else
            WORKER_DEFAULTS[:processes]
          end
          processes.times.map { Process.new(:worker, worker_options.with_defaults(WORKER_DEFAULTS)) }
        end
      end

      def dispatchers
        dispatchers_options.map do |dispatcher_options|
          recurring_tasks = parse_recurring_tasks dispatcher_options[:recurring_tasks]
          Process.new :dispatcher, dispatcher_options.merge(recurring_tasks: recurring_tasks).with_defaults(DISPATCHER_DEFAULTS)
        end
      end

      def config_from(file_or_hash, env: Rails.env)
        load_config_from(file_or_hash).then do |config|
          config = config[env.to_sym] ? config[env.to_sym] : config
          if (config.keys & DEFAULT_CONFIG.keys).any? then config
          else
            DEFAULT_CONFIG
          end
        end
      end

      def workers_options
        @workers_options ||= options_from_raw_config(:workers)
          .map { |options| options.dup.symbolize_keys }
      end

      def dispatchers_options
        @dispatchers_options ||= options_from_raw_config(:dispatchers)
          .map { |options| options.dup.symbolize_keys }
      end

      def options_from_raw_config(key)
        Array(raw_config[key])
      end

      def parse_recurring_tasks(tasks)
        Array(tasks).map do |id, options|
          RecurringTask.from_configuration(id, **options)
        end.select(&:valid?)
      end

      def load_config_from(file_or_hash)
        case file_or_hash
        when Hash
          file_or_hash.dup
        when Pathname, String
          load_config_from_file Pathname.new(file_or_hash)
        when NilClass
          load_config_from_env_location || load_config_from_default_location
        else
          raise "Solid Queue cannot be initialized with #{file_or_hash.inspect}"
        end
      end

      def load_config_from_env_location
        if ENV["SOLID_QUEUE_CONFIG"].present?
          load_config_from_file Rails.root.join(ENV["SOLID_QUEUE_CONFIG"])
        end
      end

      def load_config_from_default_location
        Rails.root.join(DEFAULT_CONFIG_FILE_PATH).then do |config_file|
          config_file.exist? ? load_config_from_file(config_file) : {}
        end
      end

      def load_config_from_file(file)
        if file.exist?
          ActiveSupport::ConfigurationFile.parse(file).deep_symbolize_keys
        else
          raise "Configuration file for Solid Queue not found in #{file}"
        end
      end
  end
end
