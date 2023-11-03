# frozen_string_literal: true

module ActiveJob
  module ConcurrencyControls
    extend ActiveSupport::Concern

    DEFAULT_CONCURRENCY_KEY = ->(*) { self.name }

    included do
      class_attribute :concurrency_limit, default: 1
      class_attribute :concurrency_key, default: DEFAULT_CONCURRENCY_KEY, instance_accessor: false
    end

    class_methods do
      def limit_concurrency(limit: 1, key: DEFAULT_CONCURRENCY_KEY)
        self.concurrency_limit = limit
        self.concurrency_key = key
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
