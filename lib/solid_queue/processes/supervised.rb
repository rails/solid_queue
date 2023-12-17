# frozen_string_literal: true

module SolidQueue::Processes
  module Supervised
    extend ActiveSupport::Concern

    included do
      attr_reader :supervisor
    end

    def supervised_by(process)
      self.mode = :supervised
      @supervisor = process
    end

    private
      def supervisor_went_away?
        supervised? && supervisor&.pid != ::Process.ppid
      end

      def supervised?
        mode.supervised?
      end

      def register_signal_handlers
        %w[ INT TERM ].each do |signal|
          trap(signal) do
            stop
            interrupt
          end
        end

        trap(:QUIT) do
          exit!
        end
      end
  end
end
