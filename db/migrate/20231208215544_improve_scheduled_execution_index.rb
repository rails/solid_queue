class ImproveScheduledExecutionIndex < ActiveRecord::Migration[7.1]
  def change
    add_index :solid_queue_scheduled_executions, [ :scheduled_at, :priority, :job_id ], name: "index_solid_queue_dispatch_all"
    remove_index :solid_queue_scheduled_executions, [ :scheduled_at, :priority ], name: "index_solid_queue_scheduled_executions"
  end
end
