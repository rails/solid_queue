class AddMissingCreatedAtIndexes < ActiveRecord::Migration[7.1]
  def change
    add_index :solid_queue_blocked_executions, :created_at, name: "index_solid_queue_blocked_executions_on_created_at"
    add_index :solid_queue_claimed_executions, :created_at, name: "index_solid_queue_claimed_executions_on_created_at"
    add_index :solid_queue_failed_executions, :created_at, name: "index_solid_queue_failed_executions_on_created_at"
    add_index :solid_queue_ready_executions, :created_at, name: "index_solid_queue_ready_executions_on_created_at"
    add_index :solid_queue_recurring_executions, :created_at, name: "index_solid_queue_recurring_executions_on_created_at"
    add_index :solid_queue_scheduled_executions, :created_at, name: "index_solid_queue_scheduled_executions_on_created_at"
  end
end
