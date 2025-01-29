# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include Callbacks # Defines callbacks needed by other concerns
      include AppExecutor, Registrable, Procline

      after_boot -> do
        if SolidQueue.connects_to.key?(:shards)
          # Record the name of the primary shard, which should be used for
          # adapter less jobs
          if SolidQueue.primary_shard.nil?
            SolidQueue.primary_shard = SolidQueue.connects_to[:shards].keys.first
          end

          # Move active_shard to first position in connects_to[:shards] Hash to
          # make it the default
          if SolidQueue.active_shard.present? &&
               SolidQueue.connects_to[:shards].key?(SolidQueue.active_shard)
            SolidQueue::Record.default_shard = SolidQueue.active_shard
          end
        end
      end

      attr_reader :name

      def initialize(*)
        @name = generate_name
        @stopped = false
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
        {}
      end

      def stop
        @stopped = true
      end

      private
        def generate_name
          [ kind.downcase, SecureRandom.hex(10) ].join("-")
        end

        def stopped?
          @stopped
        end
    end
  end
end
