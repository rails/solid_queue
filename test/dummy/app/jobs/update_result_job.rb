class UpdateResultJob < ApplicationJob
  include ActiveJob::ConcurrencyControls

  limit_concurrency limit: 1, key: ->(job_result, **) { job_result }

  def perform(job_result, name:, pause: nil)
    job_result.status += "s#{name}"
    job_result.save!

    sleep(pause) if pause

    job_result.status += "c#{name}"
    job_result.save!
  end
end
