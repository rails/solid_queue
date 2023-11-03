class UpdateResultJob < ApplicationJob
  def perform(job_result, name:, pause: 0.1)
    job_result.update!(status: "started_#{name}")
    sleep(pause)
    job_result.update!(status: "completed_#{name}")
  end
end
