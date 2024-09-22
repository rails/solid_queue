ActiveRecord::Schema[7.1].define(version: 1) do
  create_table SolidQueue::BlockedExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index [ "concurrency_key", "priority", "job_id" ], name: "index_#{SolidQueue::BlockedExecution.table_name}_for_release"
    t.index [ "expires_at", "concurrency_key" ], name: "index_#{SolidQueue::BlockedExecution.table_name}_for_maintenance"
    t.index [ "job_id" ], name: "index_#{SolidQueue::BlockedExecution.table_name}_on_job_id", unique: true
  end

  create_table SolidQueue::ClaimedExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_#{SolidQueue::ClaimedExecution.table_name}_on_job_id", unique: true
    t.index [ "process_id", "job_id" ], name: "index_#{SolidQueue::ClaimedExecution.table_name}_on_process_id_and_job_id"
  end

  create_table SolidQueue::FailedExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_#{SolidQueue::FailedExecution.table_name}_on_job_id", unique: true
  end

  create_table SolidQueue::Job.table_name, force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "active_job_id" ], name: "index_#{SolidQueue::Job.table_name}_on_active_job_id"
    t.index [ "class_name" ], name: "index_#{SolidQueue::Job.table_name}_on_class_name"
    t.index [ "finished_at" ], name: "index_#{SolidQueue::Job.table_name}_on_finished_at"
    t.index [ "queue_name", "finished_at" ], name: "index_#{SolidQueue::Job.table_name}_for_filtering"
    t.index [ "scheduled_at", "finished_at" ], name: "index_#{SolidQueue::Job.table_name}_for_alerting"
  end

  create_table SolidQueue::Pause.table_name, force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index [ "queue_name" ], name: "index_#{SolidQueue::Pause.table_name}_on_queue_name", unique: true
  end

  create_table SolidQueue::Process.table_name, force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index [ "last_heartbeat_at" ], name: "index_#{SolidQueue::Process.table_name}_on_last_heartbeat_at"
    t.index [ "name", "supervisor_id" ], name: "index_#{SolidQueue::Process.table_name}_on_name_and_supervisor_id", unique: true
    t.index [ "supervisor_id" ], name: "index_#{SolidQueue::Process.table_name}_on_supervisor_id"
  end

  create_table SolidQueue::ReadyExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_#{SolidQueue::ReadyExecution.table_name}_on_job_id", unique: true
    t.index [ "priority", "job_id" ], name: "index_solid_queue_poll_all"
    t.index [ "queue_name", "priority", "job_id" ], name: "index_solid_queue_poll_by_queue"
  end

  create_table SolidQueue::RecurringExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_#{SolidQueue::RecurringExecution.table_name}_on_job_id", unique: true
    t.index [ "task_key", "run_at" ], name: "index_#{SolidQueue::RecurringExecution.table_name}_on_task_key_and_run_at", unique: true
  end

  create_table SolidQueue::RecurringTask.table_name, force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "key" ], name: "index_#{SolidQueue::RecurringTask.table_name}_on_key", unique: true
    t.index [ "static" ], name: "index_#{SolidQueue::RecurringTask.table_name}_on_static"
  end

  create_table SolidQueue::ScheduledExecution.table_name, force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_#{SolidQueue::ScheduledExecution.table_name}_on_job_id", unique: true
    t.index [ "scheduled_at", "priority", "job_id" ], name: "index_solid_queue_dispatch_all"
  end

  create_table SolidQueue::Semaphore.table_name, force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "expires_at" ], name: "index_#{SolidQueue::Semaphore.table_name}_on_expires_at"
    t.index [ "key", "value" ], name: "index_#{SolidQueue::Semaphore.table_name}_on_key_and_value"
    t.index [ "key" ], name: "index_#{SolidQueue::Semaphore.table_name}_on_key", unique: true
  end

  add_foreign_key SolidQueue::BlockedExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
  add_foreign_key SolidQueue::ClaimedExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
  add_foreign_key SolidQueue::FailedExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
  add_foreign_key SolidQueue::ReadyExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
  add_foreign_key SolidQueue::RecurringExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
  add_foreign_key SolidQueue::ScheduledExecution.table_name, SolidQueue::Job.table_name, column: "job_id", on_delete: :cascade
end
