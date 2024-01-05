require "puma/plugin"

module Puma
  class DSL
    def solid_queue_mode(mode = :fork)
      @options[:solid_queue_mode] = mode.to_sym
    end
  end
end

Puma::Plugin.create do
  attr_reader :puma_pid, :solid_queue_pid, :log_writer

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$


    if launcher.options[:solid_queue_mode] == :async
      start_async(launcher)
    else
      start_forked(launcher)
    end
  end

  private
    def start_forked(launcher)
      launcher.events.on_booted do
        @solid_queue_pid = fork do
          Thread.new { monitor_puma }
          SolidQueue::Supervisor.start(mode: :all)
        end

        in_background do
          monitor_solid_queue
        end
      end

      launcher.events.on_stopped { stop_solid_queue }
    end

    def start_async(launcher)
      supervisor = SolidQueue::AsyncSupervisor.load
      launcher.events.on_booted { supervisor.start }
      launcher.events.on_stopped { supervisor.stop }
      launcher.events.on_restart { supervisor.stop; supervisor.start }
    end

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
      Process.waitpid(solid_queue_pid, Process::WNOHANG)
      false
    rescue Errno::ECHILD, Errno::ESRCH
      true
    end

    def puma_dead?
      Process.ppid != puma_pid
    end

    def log(...)
      log_writer.log(...)
    end
end
