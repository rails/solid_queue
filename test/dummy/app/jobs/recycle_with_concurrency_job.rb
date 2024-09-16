# frozen_string_literal: true

class RecycleWithConcurrencyJob < ApplicationJob
  limits_concurrency key: ->(nap = nil) { }

  def perform(nap = nil)
    sleep(nap) unless nap.nil?
  end
end
