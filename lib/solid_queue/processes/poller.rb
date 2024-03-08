# frozen_string_literal: true

module SolidQueue::Processes
  module Poller
    extend ActiveSupport::Concern

    included do
      attr_accessor :polling_interval
    end

    private
      def with_polling_volume
        if SolidQueue.silence_polling? && ActiveRecord::Base.logger
          if ActiveRecord::Base.logger.respond_to?(:silence)
            ActiveRecord::Base.logger.silence { yield }
          else
            ActiveRecord::Base.with(logger: Logger.new("/dev/null") { yield }
          end
        else
          yield
        end
      end

      def metadata
        super.merge(polling_interval: polling_interval)
      end
  end
end
