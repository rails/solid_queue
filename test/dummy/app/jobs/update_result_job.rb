class UpdateResultJob < ApplicationJob
  include ActiveJob::ConcurrencyControls

  def perform(job_result, name:, pause: nil, exception: nil)
    job_result.status += "s#{name}"

    sleep(pause) if pause
    raise exception.new if exception

    job_result.status += "c#{name}"
    job_result.save!
  end
end
