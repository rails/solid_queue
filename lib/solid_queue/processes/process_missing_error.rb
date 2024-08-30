module SolidQueue
  module Processes
    class ProcessMissingError < RuntimeError
      def initialize
        super("The process that was running this job no longer exists")
      end
    end
  end
end
