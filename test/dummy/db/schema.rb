# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2023_01_25_114945) do
  create_table "solid_queue_failed_jobs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "queue_name", null: false
    t.text "arguments"
    t.text "error"
    t.integer "priority", default: 0, null: false
    t.datetime "enqueued_at"
    t.index ["queue_name", "priority"], name: "index_solid_queue_failed_jobs_on_queue_name_and_priority"
  end

  create_table "solid_queue_jobs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "queue_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "claimed_by"
    t.datetime "claimed_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.index ["claimed_by"], name: "index_solid_queue_jobs_on_claimed_by"
    t.index ["queue_name", "priority", "claimed_at", "finished_at"], name: "index_solid_queue_jobs_for_claims"
  end

end
