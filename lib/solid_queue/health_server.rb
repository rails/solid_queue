# frozen_string_literal: true

require "socket"
require "logger"

module SolidQueue
  class HealthServer
    def initialize(host:, port:, logger: nil)
      @host = host
      @port = port
      @logger = logger || default_logger
      @server = nil
      @thread = nil
    end

    def start
      return if running?

      @thread = Thread.new do
        begin
          @server = TCPServer.new(@host, @port)
          log_info("listening on #{@host}:#{@port}")

          loop do
            socket = @server.accept
            begin
              request_line = socket.gets
              path = request_line&.split(" ")&.at(1) || "/"

              if path == "/" || path == "/health"
                body = "OK"
                status_line = "HTTP/1.1 200 OK"
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
        rescue => e
          log_error("failed: #{e.class}: #{e.message}")
        ensure
          begin
            @server&.close
          rescue StandardError
          end
        end
      end
    end

    def stop
      return unless running?

      begin
        @server&.close
      rescue StandardError
      end

      if @thread&.alive?
        @thread.kill
        @thread.join(1)
      end

      @server = nil
      @thread = nil
    end

    def running?
      @thread&.alive?
    end

    private

      def default_logger
        logger = Logger.new($stdout)
        logger.level = Logger::INFO
        logger.progname = "SolidQueueHTTP"
        logger
      end

      def log_info(message)
        @logger&.info(message)
      end

      def log_error(message)
        @logger&.error(message)
      end
  end
end
