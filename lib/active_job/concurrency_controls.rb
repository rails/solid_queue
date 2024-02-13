# frozen_string_literal: true

module ActiveJob
  module ConcurrencyControls
    extend ActiveSupport::Concern

    DEFAULT_CONCURRENCY_GROUP = ->(*) { self.class.name }

    included do
      class_attribute :concurrency_key, instance_accessor: false
      class_attribute :concurrency_group, default: DEFAULT_CONCURRENCY_GROUP, instance_accessor: false

      class_attribute :concurrency_limit
      class_attribute :concurrency_duration, default: SolidQueue.default_concurrency_control_period
    end

    class_methods do
      def limits_concurrency(key:, to: 1, group: DEFAULT_CONCURRENCY_GROUP, duration: SolidQueue.default_concurrency_control_period)
        self.concurrency_key = key
        self.concurrency_limit = to
        self.concurrency_group = group
        self.concurrency_duration = duration
      end
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
