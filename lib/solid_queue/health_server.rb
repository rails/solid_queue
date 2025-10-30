# frozen_string_literal: true

require "socket"
require "logger"

module SolidQueue
  class HealthServer < Processes::Base
    include Processes::Runnable

    attr_reader :host, :port, :logger

    def initialize(host:, port:, logger: nil, **options)
      @host = host
      @port = port
      @logger = logger || default_logger
      @server = nil

      super(**options)
    end

    def metadata
      super.merge(host: host, port: port)
    end

    def running?
      @thread&.alive?
    end

    private
      def run
        begin
          @server = TCPServer.new(host, port)
          log_info("listening on #{host}:#{port}")

          loop do
            break if shutting_down?

            readables, = IO.select([ @server, self_pipe[:reader] ].compact, nil, nil, 1)
            next unless readables

            if readables.include?(self_pipe[:reader])
              drain_self_pipe
            end

            if readables.include?(@server)
              handle_connection
            end
          end
        rescue Exception => exception
          handle_thread_error(exception)
        ensure
          SolidQueue.instrument(:shutdown_process, process: self) do
            run_callbacks(:shutdown) { shutdown }
          end
        end
      end

      def handle_connection
        socket = @server.accept_nonblock(exception: false)
        return unless socket.is_a?(::TCPSocket)

        begin
          request_line = socket.gets
          path = request_line&.split(" ")&.at(1) || "/"

          if path == "/" || path == "/health"
            if system_healthy?
              body = "OK"
              status_line = "HTTP/1.1 200 OK"
            else
              body = "Unhealthy"
              status_line = "HTTP/1.1 503 Service Unavailable"
            end
          else
            body = "Not Found"
            status_line = "HTTP/1.1 404 Not Found"
          end

          headers = [
            "Content-Type: text/plain",
            "Content-Length: #{body.bytesize}",
            "Connection: close"
          ].join("\r\n")

          socket.write("#{status_line}\r\n#{headers}\r\n\r\n#{body}")
        ensure
          begin
            socket.close
          rescue StandardError
          end
        end
      end

      def shutdown
        begin
          @server&.close
        rescue StandardError
        ensure
          @server = nil
        end
      end

      def set_procline
        procline "http #{host}:#{port}"
      end

      def default_logger
        logger = Logger.new($stdout)
        logger.level = Logger::INFO
        logger.progname = "SolidQueueHTTP"
        logger
      end

      def log_info(message)
        logger&.info(message)
      end

      def drain_self_pipe
        loop { self_pipe[:reader].read_nonblock(11) }
      rescue Errno::EAGAIN, Errno::EINTR, IO::EWOULDBLOCKWaitReadable
      end

      def system_healthy?
        wrap_in_app_executor do
          # If not supervised (e.g., unit tests), consider healthy
          supervisor_record = process&.supervisor
          return true unless supervisor_record

          # Supervisor must be alive
          supervisor_alive = SolidQueue::Process.where(id: supervisor_record.id).merge(SolidQueue::Process.prunable).none?

          # All supervisees must be alive (including this health server)
          supervisees_alive = supervisor_record.supervisees.merge(SolidQueue::Process.prunable).none?

          supervisor_alive && supervisees_alive
        end
      rescue StandardError => error
        log_info("health check error: #{error.class}: #{error.message}")
        false
      end
  end
end
