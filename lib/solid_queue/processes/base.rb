# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include ActiveSupport::Callbacks
      define_callbacks :boot, :shutdown

      include AppExecutor, ProcessRegistration, Interruptible, Procline

      def initialize(mode:, **)
        @mode = mode.to_s.inquiry
      end

      def start
        @stopping = false

        observe_initial_delay
        run_callbacks(:boot) { boot }

        start_loop
      ensure
        run_callbacks(:shutdown) { shutdown }
      end

      def stop
        @stopping = true
      end

      def running?
        !stopping?
      end

      private
        attr_reader :mode

        def observe_initial_delay
          interruptible_sleep(initial_jitter)
        end

        def boot
        end

        def start_loop
        end

        def shutdown
        end

        def initial_jitter
          0
        end

        def stopping?
          @stopping
        end
    end
  end
end
