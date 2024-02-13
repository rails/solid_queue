# frozen_string_literal: true

module SolidQueue
  class Configuration
    WORKER_DEFAULTS = {
      queues: "*",
      threads: 5,
      processes: 1,
      polling_interval: 0.1
    }

    DISPATCHER_DEFAULTS = {
      batch_size: 500,
      polling_interval: 1,
      concurrency_maintenance_interval: 600
    }

    def initialize(mode: :work, load_from: nil)
      @mode = mode
      @raw_config = config_from(load_from)
    end

    def processes
      case mode
      when :dispatch then dispatchers
      when :work     then workers
      when :all      then dispatchers + workers
      else           raise "Invalid mode #{mode}"
      end
    end

    def workers
      if mode.in? %i[ work all]
        workers_options.flat_map do |worker_options|
          processes = worker_options.fetch(:processes, WORKER_DEFAULTS[:processes])
          processes.times.collect { SolidQueue::Worker.new(**worker_options.with_defaults(WORKER_DEFAULTS)) }
        end
      else
        []
      end
    end

    def dispatchers
      if mode.in? %i[ dispatch all]
        dispatchers_options.flat_map do |dispatcher_options|
          SolidQueue::Dispatcher.new(**dispatcher_options)
        end
      end
    end

    def max_number_of_threads
      # At most "threads" in each worker + 1 thread for the worker + 1 thread for the heartbeat task
      workers_options.map { |options| options[:threads] }.max + 2
    end

    private
      attr_reader :raw_config, :mode

      DEFAULT_CONFIG_FILE_PATH = "config/solid_queue.yml"

      def config_from(file_or_hash, env: Rails.env)
        config = load_config_from(file_or_hash)
        config[env.to_sym] ? config[env.to_sym] : config
      end

      def workers_options
        @workers_options ||= (raw_config[:workers] || [ WORKER_DEFAULTS ])
          .map { |options| options.dup.symbolize_keys }
      end

      def dispatchers_options
        @dispatchers_options ||= (raw_config[:dispatchers] || [ DISPATCHER_DEFAULTS ])
          .map { |options| options.dup.symbolize_keys }
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
