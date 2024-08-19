class ChangeSolidQueueRecurringTasksStaticToNotNull < ActiveRecord::Migration[7.1]
  def change
    change_column_null :solid_queue_recurring_tasks, :static, false, true
  end
end
