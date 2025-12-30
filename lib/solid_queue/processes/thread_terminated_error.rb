# frozen_string_literal: true

module SolidQueue
  module Processes
    class ThreadTerminatedError < RuntimeError
      def initialize(name)
        super("Thread #{name} terminated unexpectedly")
      end
    end
  end
end
