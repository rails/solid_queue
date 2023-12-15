# frozen_string_literal: true

module SolidQueue
  class Execution
    module JobAttributes
      extend ActiveSupport::Concern

      ASSUMIBLE_ATTRIBUTES_FROM_JOB = %i[ queue_name priority ]

      class_methods do
        def assume_attributes_from_job(*attributes)
          before_create -> { assume_attributes_from_job(ASSUMIBLE_ATTRIBUTES_FROM_JOB | attributes) }
        end
      end

      private
        def assume_attributes_from_job(attributes)
          attributes.each do |attribute|
            send("#{attribute}=", job.send(attribute))
          end
        end
    end
  end
end
