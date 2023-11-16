class SequentialUpdateResultJob < UpdateResultJob
  include ActiveJob::ConcurrencyControls

  restrict_concurrency_with limit: 1, key: ->(job_result, **) { job_result }
end
