class NonOverlappingUpdateResultJob < UpdateResultJob
  limits_concurrency key: ->(job_result, **) { job_result }
end
