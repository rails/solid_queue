class InfiniteRecursionJob < ApplicationJob
  queue_as :background

  def perform
    start
  rescue SystemStackError => e
    raise ExpectedTestError, "stack level too deep", e.backtrace
  end

  private
    def start
      continue
    end

    def continue
      start_again
    end

    def start_again
      start
    end
end
