require "puma/plugin"

Puma::Plugin.create do
  attr_reader :puma_pid, :solid_queue_pid, :log_writer, :solid_queue_supervisor

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$

    in_background do
      monitor_solid_queue
    end

    launcher.events.on_booted do
      @solid_queue_pid = fork do
        Thread.new { monitor_puma }
        SolidQueue::Supervisor.start
      end
    end

    launcher.events.on_stopped { stop_solid_queue }
    launcher.events.on_restart { stop_solid_queue }
  end

  private
    def stop_solid_queue
      Process.waitpid(solid_queue_pid, Process::WNOHANG)
      log "Stopping Solid Queue..."
      Process.kill(:INT, solid_queue_pid) if solid_queue_pid
      Process.wait(solid_queue_pid)
    rescue Errno::ECHILD, Errno::ESRCH
    end

    def monitor_puma
      monitor(:puma_dead?, "Detected Puma has gone away, stopping Solid Queue...")
    end

    def monitor_solid_queue
      monitor(:solid_queue_dead?, "Detected Solid Queue has gone away, stopping Puma...")
    end

    def monitor(process_dead, message)
      loop do
        if send(process_dead)
          log message
          Process.kill(:INT, $$)
          break
        end
        sleep 2
      end
    end

    def solid_queue_dead?
      if solid_queue_started?
        Process.waitpid(solid_queue_pid, Process::WNOHANG)
      end
      false
    rescue Errno::ECHILD, Errno::ESRCH
      true
    end

    def solid_queue_started?
      solid_queue_pid.present?
    end

    def puma_dead?
      Process.ppid != puma_pid
    end

    def log(...)
      log_writer.log(...)
    end
end
