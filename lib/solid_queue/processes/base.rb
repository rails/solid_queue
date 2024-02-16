# frozen_string_literal: true

module SolidQueue
  module Processes
    class Base
      include Callbacks # Defines callbacks needed by other concerns
      include AppExecutor, Registrable, Interruptible, Procline
    end
  end
end
