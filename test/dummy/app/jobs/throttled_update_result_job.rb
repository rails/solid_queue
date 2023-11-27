class ThrottledUpdateResultJob < UpdateResultJob
  limits_concurrency to: 3, key: ->(job_result, **) { job_result }
end
