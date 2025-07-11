class DiscardableUpdateResultJob < UpdateResultJob
  limits_concurrency key: ->(job_result, **) { job_result }, on_conflict: :discard
end
