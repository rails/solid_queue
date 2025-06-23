# frozen_string_literal: true

module SolidQueue
  module LifecycleHooks
    extend ActiveSupport::Concern

    included do
      mattr_reader :lifecycle_hooks, default: { start: [], stop: [], exit: [] }
    end

    class_methods do
      def on_start(&block)
        self.lifecycle_hooks[:start] << block
      end

      def on_stop(&block)
        self.lifecycle_hooks[:stop] << block
      end

      def on_exit(&block)
        self.lifecycle_hooks[:exit] << block
      end

      def clear_hooks
        self.lifecycle_hooks[:exit] = []
        self.lifecycle_hooks[:start] = []
        self.lifecycle_hooks[:stop] = []
      end
    end

    private
      def run_start_hooks
        run_hooks_for :start
      end

      def run_stop_hooks
        run_hooks_for :stop
      end

      def run_exit_hooks
        run_hooks_for :exit
      end

      def run_hooks_for(event)
        self.class.lifecycle_hooks.fetch(event, []).each do |block|
            block.call(self)
        rescue Exception => exception
          handle_thread_error(exception)
        end
      end
  end
end
