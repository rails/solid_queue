# frozen_string_literal: true

module SolidQueue::Processes
  module Procline
    # Sets the procline ($0)
    # solid-queue-supervisor(0.1.0): <string>
    # solid-queue-worker[pipeline-1](0.1.0): <string>
    def procline(string)
      process_kind = self.class.name.demodulize.underscore.dasherize
      label = custom_name? ? "#{process_kind}[#{name}]" : process_kind
      $0 = "solid-queue-#{label}(#{SolidQueue::VERSION}): #{string}"
    end
  end
end
