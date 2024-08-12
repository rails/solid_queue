# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include Callbacks # Defines callbacks needed by other concerns
      include AppExecutor, Registrable, Interruptible, Procline

      attr_reader :name

      def initialize(*)
        @name = generate_name
      end

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
        { name: name }
      end

      private
        def generate_name
          [ kind.downcase, SecureRandom.hex(10) ].join("-")
        end
    end
  end
end
