# frozen_string_literal: true

module ActiveJob
  module ConcurrencyControls
    extend ActiveSupport::Concern

    DEFAULT_CONCURRENCY_KEY = ->(*) { self.name }

    included do
      class_attribute :concurrency_key, default: DEFAULT_CONCURRENCY_KEY, instance_accessor: false

      class_attribute :concurrency_limit, default: 0 # No limit
      class_attribute :concurrency_duration, default: SolidQueue.default_concurrency_control_period
    end

    class_methods do
      def limits_concurrency(to: 1, key: DEFAULT_CONCURRENCY_KEY, duration: SolidQueue.default_concurrency_control_period)
        self.concurrency_limit = to
        self.concurrency_key = key
        self.concurrency_duration = duration
      end
    end

    def concurrency_key
      param = self.class.concurrency_key.call(*arguments)

      case param
      when ActiveRecord::Base
        [ self.class.name, param.class.name, param.id ]
      else
        [ self.class.name, param ]
      end.compact.join("/")
    end
  end
end
