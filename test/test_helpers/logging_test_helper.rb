# frozen_string_literal: true

module LoggingTestHelper
  private
    def rails_uses_structured_event_logging?
      defined?(ActiveSupport::EventReporter) &&
        defined?(ActiveRecord::LogSubscriber) &&
        defined?(ActiveSupport::EventReporter::LogSubscriber) &&
        ActiveRecord::LogSubscriber < ActiveSupport::EventReporter::LogSubscriber
    end

    def with_polling(silence:)
      old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, silence
      yield
    ensure
      SolidQueue.silence_polling = old_silence_polling
    end

    def with_active_record_logger(logger)
      old_ar_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, logger
      structured = rails_uses_structured_event_logging?

      if structured
        old_as_ls_logger, ActiveSupport::LogSubscriber.logger = ActiveSupport::LogSubscriber.logger, logger
        old_debug_mode = ActiveSupport.event_reporter.debug_mode?
        ActiveSupport.event_reporter.debug_mode = true
      end
      yield
    ensure
      ActiveRecord::Base.logger = old_ar_logger

      if structured
        ActiveSupport::LogSubscriber.logger = old_as_ls_logger
        ActiveSupport.event_reporter.debug_mode = old_debug_mode
      end
    end
end
