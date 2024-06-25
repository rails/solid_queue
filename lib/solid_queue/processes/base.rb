# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include Callbacks # Defines callbacks needed by other concerns
      include AppExecutor, Registrable, Interruptible, Procline

      def kind
        self.class.name.demodulize
      end

      def hostname
        @hostname ||= Socket.gethostname.force_encoding(Encoding::UTF_8)
      end

      def pid
        @pid ||= ::Process.pid
      end

      def metadata
        {}
      end
    end
  end
end
