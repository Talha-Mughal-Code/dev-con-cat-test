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

ActiveRecord::Schema[7.2].define(version: 2026_09_03_000006) do
  create_table "account_modules", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "detection_module_id", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "cost_override"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "detection_module_id"], name: "index_account_modules_uniqueness", unique: true
    t.index ["account_id"], name: "index_account_modules_on_account_id"
    t.index ["detection_module_id"], name: "index_account_modules_on_detection_module_id"
  end

  create_table "accounts", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "company_name", null: false
    t.string "plan", default: "starter", null: false
    t.string "status", default: "active", null: false
    t.integer "monthly_credit_allowance", default: 0, null: false
    t.integer "credits_consumed", default: 0, null: false
    t.date "cycle_start", null: false
    t.date "cycle_end", null: false
    t.integer "baseline_daily_burn", default: 0, null: false
    t.string "billing_contact"
    t.boolean "short_circuit_on_hard_stop", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_accounts_on_public_id", unique: true
    t.check_constraint "credits_consumed >= 0", name: "accounts_credits_consumed_non_negative"
    t.check_constraint "plan IN ('starter','growth','enterprise')", name: "accounts_plan_valid"
    t.check_constraint "status IN ('active','past_due','suspended')", name: "accounts_status_valid"
  end

  create_table "activity_events", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "lead_id"
    t.integer "verification_run_id"
    t.integer "capture_session_id"
    t.integer "pixel_id"
    t.string "kind", null: false
    t.text "payload", default: "{}", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["account_id", "id"], name: "index_activity_events_on_account_id_and_id"
    t.index ["account_id"], name: "index_activity_events_on_account_id"
    t.index ["capture_session_id"], name: "index_activity_events_on_capture_session_id"
    t.index ["lead_id", "id"], name: "index_activity_events_on_lead_id_and_id"
    t.index ["lead_id"], name: "index_activity_events_on_lead_id"
    t.index ["pixel_id"], name: "index_activity_events_on_pixel_id"
    t.index ["verification_run_id"], name: "index_activity_events_on_verification_run_id"
  end

  create_table "admin_access_logs", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "account_id"
    t.string "action", null: false
    t.string "path"
    t.string "ip"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["account_id"], name: "index_admin_access_logs_on_account_id"
    t.index ["user_id", "occurred_at"], name: "index_admin_access_logs_on_user_id_and_occurred_at"
    t.index ["user_id"], name: "index_admin_access_logs_on_user_id"
  end

  create_table "capture_sessions", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "pixel_id", null: false
    t.string "public_id", null: false
    t.string "page_url"
    t.string "referrer"
    t.string "user_agent"
    t.string "visit_ip"
    t.string "submit_ip"
    t.datetime "started_at", null: false
    t.datetime "submitted_at"
    t.text "interactions", default: "[]", null: false
    t.integer "interaction_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_capture_sessions_on_account_id"
    t.index ["pixel_id"], name: "index_capture_sessions_on_pixel_id"
    t.index ["public_id"], name: "index_capture_sessions_on_public_id", unique: true
  end

  create_table "consensus_policies", force: :cascade do |t|
    t.integer "account_id"
    t.string "name", null: false
    t.integer "version", default: 1, null: false
    t.boolean "active", default: true, null: false
    t.text "rules", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "version"], name: "index_consensus_policies_on_account_id_and_version", unique: true
    t.index ["account_id"], name: "index_consensus_policies_on_account_id"
  end

  create_table "consent_certificates", force: :cascade do |t|
    t.integer "verification_run_id", null: false
    t.integer "lead_id", null: false
    t.integer "account_id", null: false
    t.string "serial", null: false
    t.integer "schema_version", default: 1, null: false
    t.datetime "issued_at", null: false
    t.text "payload", null: false
    t.string "content_digest", null: false
    t.string "prev_digest"
    t.integer "chain_index", null: false
    t.text "signature", null: false
    t.string "key_id", null: false
    t.string "algorithm", null: false
    t.datetime "revoked_at"
    t.string "revocation_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "chain_index"], name: "index_consent_certificates_on_account_id_and_chain_index", unique: true
    t.index ["account_id"], name: "index_consent_certificates_on_account_id"
    t.index ["lead_id"], name: "index_consent_certificates_on_lead_id"
    t.index ["serial"], name: "index_consent_certificates_on_serial", unique: true
    t.index ["verification_run_id"], name: "index_consent_certificates_on_verification_run_id", unique: true
  end

  create_table "credit_ledger_entries", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "verification_run_id"
    t.integer "layer_result_id"
    t.string "entry_type", null: false
    t.string "module_key"
    t.integer "amount", null: false
    t.integer "balance_after", null: false
    t.string "idempotency_key", null: false
    t.string "description"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "occurred_at"], name: "index_credit_ledger_entries_on_account_id_and_occurred_at"
    t.index ["account_id"], name: "index_credit_ledger_entries_on_account_id"
    t.index ["idempotency_key"], name: "index_credit_ledger_entries_on_idempotency_key", unique: true
    t.index ["layer_result_id"], name: "index_credit_ledger_entries_on_layer_result_id"
    t.index ["verification_run_id"], name: "index_credit_ledger_entries_on_verification_run_id"
    t.check_constraint "amount <> 0", name: "credit_ledger_entries_amount_non_zero"
    t.check_constraint "entry_type IN ('debit','refund','allowance_grant','historical_rollup','adjustment')", name: "credit_ledger_entries_type_valid"
  end

  create_table "crm_records", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "lead_id"
    t.string "crm_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.string "phone"
    t.string "email_normalized"
    t.string "phone_normalized"
    t.string "source", default: "seed", null: false
    t.datetime "recorded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "crm_id"], name: "index_crm_records_on_account_id_and_crm_id", unique: true
    t.index ["account_id", "email_normalized"], name: "index_crm_records_on_account_id_and_email_normalized"
    t.index ["account_id", "phone_normalized"], name: "index_crm_records_on_account_id_and_phone_normalized"
    t.index ["account_id"], name: "index_crm_records_on_account_id"
    t.index ["lead_id"], name: "index_crm_records_on_lead_id"
    t.check_constraint "source IN ('seed','accepted_lead')", name: "crm_records_source_valid"
  end

  create_table "detection_modules", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.string "question"
    t.integer "default_cost_in_credits", default: 1, null: false
    t.integer "wave", default: 2, null: false
    t.boolean "consent_critical", default: false, null: false
    t.boolean "hard_stop_capable", default: false, null: false
    t.boolean "in_development", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_detection_modules_on_key", unique: true
    t.check_constraint "wave IN (1,2)", name: "detection_modules_wave_valid"
  end

  create_table "layer_results", force: :cascade do |t|
    t.integer "verification_run_id", null: false
    t.integer "account_id", null: false
    t.integer "detection_module_id", null: false
    t.string "module_key", null: false
    t.string "state", default: "pending", null: false
    t.string "signal"
    t.boolean "hard_stop", default: false, null: false
    t.float "risk_contribution", default: 0.0, null: false
    t.string "summary"
    t.text "payload"
    t.text "breakdown"
    t.integer "credits_charged", default: 0, null: false
    t.integer "wave", default: 2, null: false
    t.string "error_class"
    t.string "error_message"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "latency_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_layer_results_on_account_id"
    t.index ["detection_module_id"], name: "index_layer_results_on_detection_module_id"
    t.index ["verification_run_id", "module_key"], name: "index_layer_results_on_verification_run_id_and_module_key", unique: true
    t.index ["verification_run_id"], name: "index_layer_results_on_verification_run_id"
    t.check_constraint "(state = 'completed' AND signal IS NOT NULL) OR (state <> 'completed' AND signal IS NULL)", name: "layer_results_signal_requires_completion"
    t.check_constraint "signal IS NULL OR signal IN ('pass','warn','fail','info')", name: "layer_results_signal_valid"
    t.check_constraint "state = 'completed' OR credits_charged = 0", name: "layer_results_charge_only_when_answered"
    t.check_constraint "state IN ('pending','completed','not_enabled','not_applicable','errored','skipped_insufficient_credits','timed_out')", name: "layer_results_state_valid"
  end

  create_table "leads", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "pixel_id"
    t.integer "capture_session_id"
    t.string "public_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.string "phone"
    t.string "email_normalized"
    t.string "phone_normalized"
    t.string "ip_address"
    t.string "user_agent"
    t.string "landing_page_url"
    t.string "campaign"
    t.integer "form_dwell_ms"
    t.string "trusted_form_cert_url"
    t.boolean "consent_checkbox"
    t.datetime "captured_at", null: false
    t.datetime "submitted_at"
    t.string "origin", default: "pixel", null: false
    t.string "expected_verdict_hint"
    t.bigint "current_verification_run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "captured_at"], name: "index_leads_on_account_id_and_captured_at"
    t.index ["account_id", "email_normalized"], name: "index_leads_on_account_id_and_email_normalized"
    t.index ["account_id", "phone_normalized"], name: "index_leads_on_account_id_and_phone_normalized"
    t.index ["account_id"], name: "index_leads_on_account_id"
    t.index ["capture_session_id"], name: "index_leads_on_capture_session_id"
    t.index ["pixel_id"], name: "index_leads_on_pixel_id"
    t.index ["public_id"], name: "index_leads_on_public_id", unique: true
    t.check_constraint "origin IN ('seed','pixel')", name: "leads_origin_valid"
  end

  create_table "pixels", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "public_id", null: false
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.text "allowed_origins", default: "[]", null: false
    t.string "signing_secret", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_pixels_on_account_id"
    t.index ["public_id"], name: "index_pixels_on_public_id", unique: true
    t.check_constraint "status IN ('active','paused','revoked')", name: "pixels_status_valid"
  end

  create_table "provider_fixtures", force: :cascade do |t|
    t.string "provider_key", null: false
    t.string "lead_public_id", null: false
    t.text "payload", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_key", "lead_public_id"], name: "index_provider_fixtures_on_provider_key_and_lead_public_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.integer "account_id"
    t.string "role", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "last_login_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.check_constraint "(role = 'super_admin' AND account_id IS NULL) OR (role <> 'super_admin' AND account_id IS NOT NULL)", name: "users_account_scoping_valid"
    t.check_constraint "role IN ('super_admin','account_admin','member')", name: "users_role_valid"
  end

  create_table "verification_runs", force: :cascade do |t|
    t.integer "lead_id", null: false
    t.integer "account_id", null: false
    t.integer "consensus_policy_id", null: false
    t.string "status", default: "pending", null: false
    t.string "verdict"
    t.string "verdict_code"
    t.float "risk_score"
    t.float "confidence_score"
    t.text "reasons", default: "[]", null: false
    t.integer "coverage_applicable", default: 0, null: false
    t.integer "coverage_answered", default: 0, null: false
    t.integer "credits_estimated", default: 0, null: false
    t.integer "credits_charged", default: 0, null: false
    t.boolean "short_circuited", default: false, null: false
    t.integer "attempt", default: 1, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_verification_runs_on_account_id_and_created_at"
    t.index ["account_id", "verdict"], name: "index_verification_runs_on_account_id_and_verdict"
    t.index ["account_id"], name: "index_verification_runs_on_account_id"
    t.index ["consensus_policy_id"], name: "index_verification_runs_on_consensus_policy_id"
    t.index ["lead_id"], name: "index_verification_runs_on_lead_id"
    t.check_constraint "(status = 'completed' AND verdict IS NOT NULL) OR (status <> 'completed' AND verdict IS NULL)", name: "verification_runs_verdict_requires_completion"
    t.check_constraint "status IN ('pending','running','completed','halted_insufficient_credits','errored')", name: "verification_runs_status_valid"
    t.check_constraint "verdict IS NULL OR verdict IN ('accept','review','reject')", name: "verification_runs_verdict_valid"
  end

  add_foreign_key "account_modules", "accounts"
  add_foreign_key "account_modules", "detection_modules"
  add_foreign_key "activity_events", "accounts"
  add_foreign_key "activity_events", "capture_sessions"
  add_foreign_key "activity_events", "leads"
  add_foreign_key "activity_events", "pixels"
  add_foreign_key "activity_events", "verification_runs"
  add_foreign_key "admin_access_logs", "accounts"
  add_foreign_key "admin_access_logs", "users"
  add_foreign_key "capture_sessions", "accounts"
  add_foreign_key "capture_sessions", "pixels"
  add_foreign_key "consensus_policies", "accounts"
  add_foreign_key "consent_certificates", "accounts"
  add_foreign_key "consent_certificates", "leads"
  add_foreign_key "consent_certificates", "verification_runs"
  add_foreign_key "credit_ledger_entries", "accounts"
  add_foreign_key "credit_ledger_entries", "layer_results"
  add_foreign_key "credit_ledger_entries", "verification_runs"
  add_foreign_key "crm_records", "accounts"
  add_foreign_key "crm_records", "leads"
  add_foreign_key "layer_results", "accounts"
  add_foreign_key "layer_results", "detection_modules"
  add_foreign_key "layer_results", "verification_runs"
  add_foreign_key "leads", "accounts"
  add_foreign_key "leads", "capture_sessions"
  add_foreign_key "leads", "pixels"
  add_foreign_key "pixels", "accounts"
  add_foreign_key "users", "accounts"
  add_foreign_key "verification_runs", "accounts"
  add_foreign_key "verification_runs", "consensus_policies"
  add_foreign_key "verification_runs", "leads"
end
