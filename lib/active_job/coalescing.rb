# frozen_string_literal: true

module ActiveJob
  module Coalescing
    extend ActiveSupport::Concern

    included do
      class_attribute :coalesce_key, instance_accessor: false
    end

    attr_accessor :coalesce_status

    class_methods do
      def coalesce(key:)
        self.coalesce_key = key
      end
    end

    def coalesce_key
      if self.class.coalesce_key
        param = compute_concurrency_parameter(self.class.coalesce_key)

        case param
        when ActiveRecord::Base
          [ coalesce_group, param.class.name, param.id ]
        else
          [ coalesce_group, param ]
        end.compact.join("/")
      end
    end

    # Retries continue work that has already started, so they're never coalesced
    def coalesced?
      coalesce_key.present? && executions.zero?
    end

    private
      # A batch waits for its own jobs, so a call in a batch only joins a job in the same batch
      def coalesce_group
        [ ("Batch/#{batch_id}" if batch_id), self.class.name ].compact.join("/")
      end
  end
end
