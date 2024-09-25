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
      concurrency_maintenance_interval: 600
    }

    DEFAULT_CONFIG_FILE_PATH = "config/queue.yml"
    DEFAULT_RECURRING_SCHEDULE_FILE_PATH = "config/recurring.yml"

    def initialize(**options)
      @options = options.with_defaults(default_options)
    end

    def configured_processes
      if only_work? then workers
      else
        dispatchers + workers + schedulers
      end
    end

    def max_number_of_threads
      # At most "threads" in each worker + 1 thread for the worker + 1 thread for the heartbeat task
      workers_options.map { |options| options[:threads] }.max + 2
    end

    private
      attr_reader :options

      def default_options
        {
          config_file: Rails.root.join(ENV["SOLID_QUEUE_CONFIG"] || DEFAULT_CONFIG_FILE_PATH),
          recurring_schedule_file: Rails.root.join(ENV["SOLID_QUEUE_RECURRING_SCHEDULE"] || DEFAULT_RECURRING_SCHEDULE_FILE_PATH),
          only_work: false,
          only_dispatch: false,
          skip_recurring: false
        }
      end

      def only_work?
        options[:only_work]
      end

      def only_dispatch?
        options[:only_dispatch]
      end

      def skip_recurring_tasks?
        options[:skip_recurring] || only_work?
      end

      def workers
        workers_options.flat_map do |worker_options|
          processes = worker_options.fetch(:processes, WORKER_DEFAULTS[:processes])
          processes.times.map { Process.new(:worker, worker_options.with_defaults(WORKER_DEFAULTS)) }
        end
      end

      def dispatchers
        dispatchers_options.map do |dispatcher_options|
          Process.new :dispatcher, dispatcher_options.with_defaults(DISPATCHER_DEFAULTS)
        end
      end

      def schedulers
        if !skip_recurring_tasks? && recurring_tasks.any?
          [ Process.new(:scheduler, recurring_tasks: recurring_tasks) ]
        else
          []
        end
      end

      def workers_options
        @workers_options ||= processes_config.fetch(:workers, [])
          .map { |options| options.dup.symbolize_keys }
      end

      def dispatchers_options
        @dispatchers_options ||= processes_config.fetch(:dispatchers, [])
          .map { |options| options.dup.symbolize_keys }
      end

      def recurring_tasks
        @recurring_tasks ||= recurring_tasks_config.map do |id, options|
          RecurringTask.from_configuration(id, **options)
        end.select(&:valid?)
      end

      def processes_config
        @processes_config ||= config_from \
          options.slice(:workers, :dispatchers).presence || options[:config_file],
          keys: [ :workers, :dispatchers ],
          fallback: { workers: [ WORKER_DEFAULTS ], dispatchers: [ DISPATCHER_DEFAULTS ] }
      end

      def recurring_tasks_config
        @recurring_tasks_config ||= config_from options[:recurring_schedule_file]
      end


      def config_from(file_or_hash, keys: [], fallback: {}, env: Rails.env)
        load_config_from(file_or_hash).then do |config|
          config = config[env.to_sym] ? config[env.to_sym] : config
          config = config.slice(*keys) if keys.any? && config.present?

          if config.empty? then fallback
          else
            config
          end
        end
      end

      def load_config_from(file_or_hash)
        case file_or_hash
        when Hash
          file_or_hash.dup
        when Pathname, String
          load_config_from_file Pathname.new(file_or_hash)
        when NilClass
          {}
        else
          raise "Solid Queue cannot be initialized with #{file_or_hash.inspect}"
        end
      end

      def load_config_from_file(file)
        if file.exist?
          ActiveSupport::ConfigurationFile.parse(file).deep_symbolize_keys
        else
          {}
        end
      end
  end
end
