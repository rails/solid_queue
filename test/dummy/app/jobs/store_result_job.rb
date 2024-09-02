class StoreResultJob < ApplicationJob
  queue_as :background

  def perform(value, status: :completed, pause: nil, exception: nil, exit_value: nil)
    result = JobResult.create!(queue_name: queue_name, status: "started", value: value)

    sleep(pause) if pause
    raise exception.new if exception
    exit!(exit_value) if exit_value

    result.update!(status: status)
  end
end
