# frozen_string_literal: true

module SolidQueue
  class Execution
    module JobAttributes
      extend ActiveSupport::Concern

      included do
        class_attribute :assumable_attributes_from_job, instance_accessor: false, default: %i[ queue_name priority ]
      end

      class_methods do
        def assumes_attributes_from_job(*attribute_names)
          self.assumable_attributes_from_job |= attribute_names
          before_create -> { assume_attributes_from_job }
        end

        def attributes_from_job(job)
          job.attributes.symbolize_keys.slice(*assumable_attributes_from_job)
        end
      end

      private
        def assume_attributes_from_job
          self.class.assumable_attributes_from_job.each do |attribute|
            send("#{attribute}=", job.send(attribute))
          end
        end
    end
  end
end
