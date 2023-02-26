class StoreResultJob < ApplicationJob
  queue_as :background

  def perform(value, pause: nil, exception: nil, exit: nil)
    result = JobResult.create!(queue_name: queue_name, status: "started", value: value)

    sleep(pause) if pause
    raise exception.new if exception
    exit! if exit

    result.update!(status: "completed")
  end
end
