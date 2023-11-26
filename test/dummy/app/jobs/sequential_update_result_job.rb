class SequentialUpdateResultJob < UpdateResultJob
  limits_concurrency key: ->(job_result, **) { job_result }, duration: 2.seconds
end
