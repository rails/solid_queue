class ProviderJobIdJob < ApplicationJob
  def perform
    JobBuffer.add "provider_job_id: #{provider_job_id}"
  end
end
