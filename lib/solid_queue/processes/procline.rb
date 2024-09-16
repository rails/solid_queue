# frozen_string_literal: true

module SolidQueue::Processes
  module Procline
    # Sets the procline ($0)
    # solid-queue-supervisor(0.1.0): <string>
    def procline(string)
      $0 = "solid-queue-#{self.class.name.demodulize.underscore.dasherize}(#{SolidQueue::VERSION}): #{string}"
    end
  end
end
