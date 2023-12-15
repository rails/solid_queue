# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include ActiveSupport::Callbacks
      define_callbacks :boot, :shutdown

      include AppExecutor, Registrable, Interruptible, Procline

      private
        def observe_initial_delay
          interruptible_sleep(initial_jitter)
        end

        def boot
        end

        def shutdown
        end

        def initial_jitter
          0
        end
    end
  end
end
