# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include Callbacks # Defines callbacks needed by other concerns
      include AppExecutor, Registrable, Interruptible, Procline

      private
        def observe_initial_delay
          interruptible_sleep(initial_jitter)
        end

        def initial_jitter
          0
        end
    end
  end
end
