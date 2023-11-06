class SequentialUpdateResultJob < UpdateResultJob
  include ActiveJob::ConcurrencyControls

  limit_concurrency limit: 1, key: ->(job_result, **) { job_result }
end
