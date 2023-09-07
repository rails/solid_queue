class FixReadyExecutionIndex < ActiveRecord::Migration[7.0]
  def change
    add_index :solid_queue_ready_executions, [ :queue_name, :priority ]
    remove_index :solid_queue_ready_executions, [ :priority, :queue_name ]
  end
end
