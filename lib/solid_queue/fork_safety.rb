# frozen_string_literal: true

module SolidQueue
  module ForkSafety
    def _fork
      Record.clear_all_connections!

      pid = super

      pid
    end
  end
end

Process.singleton_class.prepend(SolidQueue::ForkSafety)
