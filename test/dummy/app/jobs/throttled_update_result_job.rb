class ThrottledUpdateResultJob < UpdateResultJob
  include ActiveJob::ConcurrencyControls

  limit_concurrency limit: 3, key: ->(job_result, **) { job_result }
end
