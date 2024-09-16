# frozen_string_literal: true

class RecycleJob < ApplicationJob
  def perform(nap = nil)
    sleep(nap) unless nap.nil?
  end
end
