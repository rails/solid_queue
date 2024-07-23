# frozen_string_literal: true

module SolidQueue
  class Supervisor
    module Pidfiled
      extend ActiveSupport::Concern

      included do
        before_boot :setup_pidfile
        after_shutdown :delete_pidfile
      end

      private
        def setup_pidfile
          if path = SolidQueue.supervisor_pidfile
            @pidfile = Pidfile.new(path).tap(&:setup)
          end
        end

        def delete_pidfile
          @pidfile&.delete
        end
    end
  end
end
