# frozen_string_literal: true

module SolidQueue
  class Execution
    module BatchPreparable
      extend ActiveSupport::Concern

      included do
        after_create :create_batch_execution
      end

      def create_batch_execution
        BatchExecution.create_all_from_jobs([ job ])
      end

      class_methods do
        def create_all_from_jobs(jobs)
          super.tap do
            BatchExecution.create_all_from_jobs(jobs)
          end
        end
      end
    end
  end
end
