class CreateSolidQueueTables < ActiveRecord::Migration[7.2]
  create_table "solid_queue_blocked_executions", if_not_exists: true do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index [ "concurrency_key", "priority", "job_id" ], name: "index_solid_queue_blocked_executions_for_release"
    t.index [ "expires_at", "concurrency_key" ], name: "index_solid_queue_blocked_executions_for_maintenance"
  end

  create_table "solid_queue_claimed_executions", if_not_exists: true do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.references :process, index: false
    t.datetime "created_at", null: false
    t.index [ "process_id", "job_id" ], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", if_not_exists: true  do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.text "error"
    t.datetime "created_at", null: false
  end

  create_table "solid_queue_jobs", if_not_exists: true do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false, index: true
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id", index: true
    t.datetime "scheduled_at"
    t.datetime "finished_at", index: true
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "queue_name", "finished_at" ], name: "index_solid_queue_jobs_for_filtering"
    t.index [ "scheduled_at", "finished_at" ], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", if_not_exists: true do |t|
    t.string "queue_name", null: false, index: { unique: true }
    t.datetime "created_at", null: false
  end

  create_table "solid_queue_processes", if_not_exists: true do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false, index: true
    t.references :supervisor
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index [ "name", "supervisor_id" ], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
  end

  create_table "solid_queue_ready_executions", if_not_exists: true do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index [ "priority", "job_id" ], name: "index_solid_queue_poll_all"
    t.index [ "queue_name", "priority", "job_id" ], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", if_not_exists: true do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index [ "task_key", "run_at" ], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", if_not_exists: true do |t|
    t.string "key", null: false, index: { unique: true }
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false, index: true
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "solid_queue_scheduled_executions", if_not_exists: true do |t|
    t.references :job, null: false, index: { unique: true }, foreign_key: { to_table: :solid_queue_jobs, on_delete: :cascade }
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index [ "scheduled_at", "priority", "job_id" ], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", if_not_exists: true do |t|
    t.string "key", null: false, index: { unique: true }
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false, index: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "key", "value" ], name: "index_solid_queue_semaphores_on_key_and_value"
  end
end
