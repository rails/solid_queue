# frozen_string_literal: true

module ActiveJob
  module ConcurrencyControls
    extend ActiveSupport::Concern

    DEFAULT_CONCURRENCY_GROUP = ->(*) { self.class.name }
    CONCURRENCY_ON_CONFLICT_BEHAVIOUR = %i[ block discard ]

    included do
      class_attribute :concurrency_key, instance_accessor: false
      class_attribute :concurrency_group, default: DEFAULT_CONCURRENCY_GROUP, instance_accessor: false

      class_attribute :concurrency_limit
      class_attribute :concurrency_duration, default: SolidQueue.default_concurrency_control_period
      class_attribute :concurrency_on_conflict, default: :block
      class_attribute :concurrency_acquisition, instance_accessor: false
    end

    class_methods do
      def limits_concurrency(key:, to: 1, group: DEFAULT_CONCURRENCY_GROUP, duration: SolidQueue.default_concurrency_control_period, on_conflict: :block, acquire: nil)
        self.concurrency_key = key
        self.concurrency_limit = to
        self.concurrency_group = group
        self.concurrency_duration = duration
        self.concurrency_on_conflict = on_conflict.presence_in(CONCURRENCY_ON_CONFLICT_BEHAVIOUR) || :block
        self.concurrency_acquisition = acquire && SolidQueue.validate_concurrency_lock_acquisition!(acquire)
      end
    end

    # Accepts +acquire+ on top of Active Job's own options, to choose when this
    # particular enqueue acquires the concurrency lock:
    #
    #   MyJob.set(acquire: :on_dispatch).perform_later(record)
    def set(options = {})
      if options.key?(:acquire)
        @concurrency_acquisition = options[:acquire] && SolidQueue.validate_concurrency_lock_acquisition!(options[:acquire])
      end

      super
    end

    def concurrency_key
      if self.class.concurrency_key
        param = compute_concurrency_parameter(self.class.concurrency_key)

        case param
        when ActiveRecord::Base
          [ concurrency_group, param.class.name, param.id ]
        else
          [ concurrency_group, param ]
        end.compact.join("/")
      end
    end

    def concurrency_limited?
      concurrency_key.present?
    end

    # When this job acquires its concurrency lock: set for this enqueue, for the
    # job class, or globally, in that order.
    def concurrency_lock_acquisition
      @concurrency_acquisition || self.class.concurrency_acquisition || SolidQueue.concurrency_lock_acquisition
    end

    private
      def concurrency_group
        compute_concurrency_parameter(self.class.concurrency_group)
      end

      def compute_concurrency_parameter(option)
        case option
        when String, Symbol
          option.to_s
        when Proc
          instance_exec(*arguments, &option)
        end
      end
  end
end
