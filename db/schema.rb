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

ActiveRecord::Schema[8.1].define(version: 2026_07_12_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "activations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "activated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "device_name"
    t.string "hardware_id", null: false
    t.uuid "license_id", null: false
    t.boolean "provisional", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["license_id"], name: "index_activations_on_license_id"
  end

  create_table "admin_users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
  end

  create_table "affiliate_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "affiliate_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["affiliate_id"], name: "index_affiliate_tokens_on_affiliate_id", unique: true
    t.index ["token"], name: "index_affiliate_tokens_on_token", unique: true
  end

  create_table "affiliates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code", null: false
    t.integer "commission_percent", default: 20, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.string "payout_email"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_affiliates_on_code", unique: true
    t.index ["email"], name: "index_affiliates_on_email", unique: true
  end

  create_table "customers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_customers_on_email", unique: true
  end

  create_table "licenses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.uuid "customer_id"
    t.datetime "expires_at"
    t.string "license_key", null: false
    t.integer "licensed_version"
    t.integer "max_activations"
    t.string "migration_source"
    t.uuid "product_id", null: false
    t.datetime "reminded_at"
    t.string "status", null: false
    t.string "stripe_customer_id"
    t.string "stripe_payment_id"
    t.string "stripe_price_id"
    t.boolean "trial", default: false, null: false
    t.string "update_policy"
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_licenses_on_customer_id"
    t.index ["license_key"], name: "index_licenses_on_license_key", unique: true
    t.index ["product_id", "stripe_payment_id"], name: "index_licenses_on_product_and_stripe_payment", unique: true, where: "(stripe_payment_id IS NOT NULL)"
    t.index ["product_id"], name: "index_licenses_on_product_id"
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "customer_id", null: false
    t.string "kind", null: false
    t.string "reference_id", null: false
    t.datetime "sent_at"
    t.datetime "updated_at", null: false
    t.index ["customer_id", "kind", "reference_id"], name: "index_notifications_dedup", unique: true
    t.index ["customer_id"], name: "index_notifications_on_customer_id"
  end

  create_table "payments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "affiliate_id"
    t.integer "amount_cents"
    t.integer "commission_cents"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "kind", null: false
    t.uuid "license_id", null: false
    t.string "stripe_payment_intent", null: false
    t.datetime "updated_at", null: false
    t.index ["affiliate_id"], name: "index_payments_on_affiliate_id"
    t.index ["license_id"], name: "index_payments_on_license_id"
    t.index ["stripe_payment_intent"], name: "index_payments_on_stripe_payment_intent", unique: true
  end

  create_table "payouts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "affiliate_id", null: false
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.string "note"
    t.datetime "paid_at", null: false
    t.datetime "updated_at", null: false
    t.index ["affiliate_id"], name: "index_payouts_on_affiliate_id"
  end

  create_table "portal_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "customer_id", null: false
    t.datetime "expires_at", null: false
    t.uuid "product_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "product_id"], name: "index_portal_tokens_on_customer_id_and_product_id", unique: true
    t.index ["customer_id"], name: "index_portal_tokens_on_customer_id"
    t.index ["product_id"], name: "index_portal_tokens_on_product_id"
    t.index ["token"], name: "index_portal_tokens_on_token", unique: true
  end

  create_table "products", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "affiliate_commission_percent"
    t.string "affiliate_landing_url"
    t.string "affiliate_transactional_id"
    t.string "api_key", null: false
    t.string "bundle_identifier", null: false
    t.string "checkout_cancel_url"
    t.string "checkout_success_url"
    t.datetime "created_at", null: false
    t.integer "current_version", default: 1, null: false
    t.string "download_url"
    t.string "eddsa_private_key", null: false
    t.string "eddsa_public_key", null: false
    t.string "expiry_reminder_transactional_id"
    t.string "license_prefix", null: false
    t.string "loops_api_key"
    t.string "loops_mailing_list_id"
    t.string "loops_transactional_id"
    t.integer "max_activations_default"
    t.string "name", null: false
    t.string "purchase_transactional_id"
    t.string "refund_transactional_id"
    t.string "sender_email"
    t.string "slug", null: false
    t.string "stripe_product_id"
    t.string "stripe_secret_key"
    t.string "stripe_webhook_secret"
    t.integer "trial_days"
    t.integer "update_duration_days"
    t.string "update_policy", null: false
    t.datetime "updated_at", null: false
    t.index ["api_key"], name: "index_products_on_api_key", unique: true
    t.index ["bundle_identifier"], name: "index_products_on_bundle_identifier", unique: true
    t.index ["license_prefix"], name: "index_products_on_license_prefix", unique: true
    t.index ["slug"], name: "index_products_on_slug", unique: true
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  add_foreign_key "activations", "licenses"
  add_foreign_key "affiliate_tokens", "affiliates"
  add_foreign_key "licenses", "customers"
  add_foreign_key "licenses", "products"
  add_foreign_key "notifications", "customers"
  add_foreign_key "payments", "affiliates"
  add_foreign_key "payments", "licenses"
  add_foreign_key "payouts", "affiliates"
  add_foreign_key "portal_tokens", "customers"
  add_foreign_key "portal_tokens", "products"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
