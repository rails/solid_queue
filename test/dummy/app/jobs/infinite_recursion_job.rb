class InfiniteRecursionJob < ApplicationJob
  queue_as :background

  def perform
    start
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
