begin
  require "active_job/continuation"
rescue LoadError
  # Zeitwerk requires that we define the constant
  class ContinuableJob; end
  return
end

class ContinuableJob < ApplicationJob
  include ActiveJob::Continuable

  def perform(result, pause: 0)
    step :step_one do
      result.update!(queue_name: queue_name, status: "started", value: "step_one")
      sleep pause if pause > 0
      result.update!(queue_name: queue_name, status: "stepped", value: "step_one")
    end
    step :step_two do
      sleep pause if pause > 0
      result.update!(queue_name: queue_name, status: "stepped", value: "step_two")
    end
  end
end
