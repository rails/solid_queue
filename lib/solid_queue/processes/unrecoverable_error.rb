# frozen_string_literal: true

module SolidQueue
  module Processes
    # Errors that mean the process raising them can no longer account for the
    # work it holds, so it should stop and let its supervisor replace it
    class UnrecoverableError < RuntimeError; end
  end
end
