require "fugit"

module SolidQueue
  module RecurringJobs
    class Entry
      attr_accessor :id, :schedule, :job_class, :arguments

      def self.initialize_all(schedule)
        schedule.collect do |id, options|
          new(id, **options)
        end.select(&:valid?)
      end

      def initialize(id, **options)
        @id = id
        @job_class = options[:class].safe_constantize
        @arguments = options[:args]
        @schedule = Fugit.parse(options[:schedule])
      end

      def delay_from_now
        [ (next_time - Time.current).to_f, 0 ].max
      end

      def next_time
        schedule.next_time.utc
      end

      def enqueue
        job_class.perform_later(*arguments)
      end

      def valid?
        schedule.instance_of?(Fugit::Cron)
      end

      def to_s
        "#{job_class.name}.perform_later(#{arguments.map(&:inspect).join(",")}) with schedule #{schedule.original}"
      end
    end
  end
end
