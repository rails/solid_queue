require "puma/plugin"

module Puma
  class DSL
    def solid_queue_mode(mode = :fork)
      @options[:solid_queue_mode] = mode.to_sym
    end
  end
end

Puma::Plugin.create do
  attr_reader :puma_pid, :solid_queue_pid, :log_writer, :solid_queue_supervisor

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
      in_background do
        monitor_solid_queue
      end

      if Gem::Version.new(Puma::Const::VERSION) < Gem::Version.new("7")
        launcher.events.on_booted do
          @solid_queue_pid = fork do
            Thread.new { monitor_puma }
            SolidQueue::Supervisor.start(mode: :fork)
          end
        end

        launcher.events.on_stopped { stop_solid_queue_fork }
        launcher.events.on_restart { stop_solid_queue_fork }
      else
        launcher.events.after_booted do
          @solid_queue_pid = fork do
            Thread.new { monitor_puma }
            start_solid_queue(mode: :fork)
          end
        end

        launcher.events.after_stopped { stop_solid_queue_fork }
        launcher.events.before_restart { stop_solid_queue_fork }
      end
    end

    def start_async(launcher)
      if Gem::Version.new(Puma::Const::VERSION) < Gem::Version.new("7")
        launcher.events.on_booted do
          start_solid_queue(mode: :async, standalone: false)
        end

        launcher.events.on_stopped { solid_queue_supervisor&.stop }

        launcher.events.on_restart do
          solid_queue_supervisor&.stop
          start_solid_queue(mode: :async, standalone: false)
        end
      else
        launcher.events.after_booted do
          start_solid_queue(mode: :async, standalone: false)
        end

        launcher.events.after_stopped { solid_queue_supervisor&.stop }

        launcher.events.before_restart do
          solid_queue_supervisor&.stop
          start_solid_queue(mode: :async, standalone: false)
        end
      end
    end

    def start_solid_queue(**options)
      @solid_queue_supervisor = SolidQueue::Supervisor.start(**options)
    end

    def stop_solid_queue_fork
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
      monitor(:solid_queue_fork_dead?, "Detected Solid Queue has gone away, stopping Puma...")
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

    def solid_queue_fork_dead?
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
