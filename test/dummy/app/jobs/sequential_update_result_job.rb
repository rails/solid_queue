class SequentialUpdateResultJob < UpdateResultJob
  restrict_concurrency_with limit: 1, key: ->(job_result, **) { job_result }
end
