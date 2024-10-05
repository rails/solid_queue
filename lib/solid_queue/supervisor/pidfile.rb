# frozen_string_literal: true

module SolidQueue
  class Supervisor::Pidfile
    def initialize(path)
      @path = path
      @pid = ::Process.pid
    end

    def setup
      check_status
      write_file
      set_at_exit_hook
    end

    def delete
      delete_file
    end

    private
      attr_reader :path, :pid

      def check_status
        if ::File.exist?(path)
          existing_pid = ::File.open(path).read.strip.to_i
          existing_pid > 0 && ::Process.kill(0, existing_pid)

          already_running!
        else
          FileUtils.mkdir_p File.dirname(path)
        end
      rescue Errno::ESRCH
        # Process is dead, ignore, just delete the file
        delete
      rescue Errno::EPERM
        already_running!
      end

      def write_file
        ::File.open(path, ::File::CREAT | ::File::EXCL | ::File::WRONLY) { |file| file.write(pid.to_s) }
      rescue Errno::EEXIST
        check_status
        retry
      end

      def set_at_exit_hook
        at_exit { delete if ::Process.pid == pid }
      end

      def delete_file
        ::File.delete(path) if ::File.exist?(path)
      end

      def already_running!
        abort "A Solid Queue supervisor is already running. Check #{path}"
      end
  end
end
