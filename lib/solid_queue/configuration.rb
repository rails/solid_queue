# frozen_string_literal: true

module SolidQueue
  class Configuration
    include ActiveModel::Model

    validate :ensure_configured_processes
    validate :ensure_valid_recurring_tasks
    validate :ensure_correctly_sized_thread_pool

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

    def error_messages
      if configured_processes.none?
        "No workers or processed configured. Exiting..."
      else
        error_messages = invalid_tasks.map do |task|
            all_messages = task.errors.full_messages.map { |msg| "\t#{msg}" }.join("\n")
            "#{task.key}:\n#{all_messages}"
          end
          .join("\n")

        "Invalid processes configured:\n#{error_messages}"
      end
    end

    private
      attr_reader :options

      def ensure_configured_processes
        unless configured_processes.any?
          errors.add(:base, "No processes configured")
        end
      end

      def ensure_valid_recurring_tasks
        unless skip_recurring_tasks? || invalid_tasks.none?
          error_messages = invalid_tasks.map do |task|
            "- #{task.key}: #{task.errors.full_messages.join(", ")}"
          end

          errors.add(:base, "Invalid recurring tasks:\n#{error_messages.join("\n")}")
        end
      end

      def ensure_correctly_sized_thread_pool
        if (db_pool_size = SolidQueue::Record.connection_pool&.size) && db_pool_size < estimated_number_of_threads
          errors.add(:base, "Solid Queue is configured to use #{estimated_number_of_threads} threads but the " +
            "database connection pool is #{db_pool_size}. Increase it in `config/database.yml`")
        end
      end

      def default_options
        {
          config_file: Rails.root.join(ENV["SOLID_QUEUE_CONFIG"] || DEFAULT_CONFIG_FILE_PATH),
          recurring_schedule_file: Rails.root.join(ENV["SOLID_QUEUE_RECURRING_SCHEDULE"] || DEFAULT_RECURRING_SCHEDULE_FILE_PATH),
          only_work: false,
          only_dispatch: false,
          skip_recurring: ActiveModel::Type::Boolean.new.cast(ENV["SOLID_QUEUE_SKIP_RECURRING"])
        }
      end

      def invalid_tasks
        recurring_tasks.select(&:invalid?)
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
          RecurringTask.from_configuration(id, **options) if options&.has_key?(:schedule)
        end.compact
      end

      def processes_config
        @processes_config ||= config_from \
          options.slice(:workers, :dispatchers).presence || options[:config_file],
          keys: [ :workers, :dispatchers ],
          fallback: { workers: [ WORKER_DEFAULTS ], dispatchers: [ DISPATCHER_DEFAULTS ] }
      end

      def recurring_tasks_config
        @recurring_tasks_config ||= begin
          config_from options[:recurring_schedule_file]
        end
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

      def estimated_number_of_threads
        # At most "threads" in each worker + 1 thread for the worker + 1 thread for the heartbeat task
        thread_count = workers_options.map { |options| options.fetch(:threads, WORKER_DEFAULTS[:threads]) }.max
        (thread_count || 1) + 2
      end
  end
end
