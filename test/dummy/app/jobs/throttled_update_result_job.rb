class ThrottledUpdateResultJob < UpdateResultJob
  restrict_concurrency_with limit: 3, key: ->(job_result, **) { job_result }
end
