class AddSupervisorIdToProcesses < ActiveRecord::Migration[7.1]
  def change
    add_reference :solid_queue_processes, :supervisor, index: true
  end
end
