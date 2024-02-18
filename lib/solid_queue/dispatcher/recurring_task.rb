require "fugit"

module SolidQueue
  class Dispatcher::RecurringTask
    class << self
      def wrap(args)
        args.first.is_a?(self) ? args.first : from_configuration(args.first, **args.second)
      end

      def from_configuration(key, **options)
        new(key, class_name: options[:class], schedule: options[:schedule], arguments: options[:args])
      end
    end

    attr_reader :key, :schedule, :class_name, :arguments

    def initialize(key, class_name:, schedule:, arguments: nil)
      @key = key
      @class_name = class_name
      @schedule = Fugit.parse(schedule)
      @arguments = Array(arguments)
    end

    def delay_from_now
      [ (next_time - Time.current).to_f, 0 ].max
    end

    def next_time
      schedule.next_time.utc
    end

    def enqueue
      SolidQueue.logger.info("[SolidQueue] Dispatching recurring task #{self}")
      job_class.perform_later(*arguments)
    end

    def valid?
      schedule.instance_of?(Fugit::Cron)
    end

    def to_s
      "#{class_name}.perform_later(#{arguments.map(&:inspect).join(",")}) with schedule #{schedule.original}"
    end

    private
      def job_class
        @job_class ||= class_name.safe_constantize
      end
  end
end