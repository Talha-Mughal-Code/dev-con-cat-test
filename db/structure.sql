CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "public_id" varchar NOT NULL, "company_name" varchar NOT NULL, "plan" varchar DEFAULT 'starter' NOT NULL, "status" varchar DEFAULT 'active' NOT NULL, "monthly_credit_allowance" integer DEFAULT 0 NOT NULL, "credits_consumed" integer DEFAULT 0 NOT NULL, "cycle_start" date NOT NULL, "cycle_end" date NOT NULL, "baseline_daily_burn" integer DEFAULT 0 NOT NULL, "billing_contact" varchar, "short_circuit_on_hard_stop" boolean DEFAULT 1 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT accounts_plan_valid CHECK (plan IN ('starter','growth','enterprise')), CONSTRAINT accounts_status_valid CHECK (status IN ('active','past_due','suspended')), CONSTRAINT accounts_credits_consumed_non_negative CHECK (credits_consumed >= 0));
CREATE UNIQUE INDEX "index_accounts_on_public_id" ON "accounts" ("public_id");
CREATE TABLE IF NOT EXISTS "detection_modules" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "key" varchar NOT NULL, "name" varchar NOT NULL, "question" varchar, "default_cost_in_credits" integer DEFAULT 1 NOT NULL, "wave" integer DEFAULT 2 NOT NULL, "fail_closed" boolean DEFAULT 0 NOT NULL, "hard_stop_capable" boolean DEFAULT 0 NOT NULL, "in_development" boolean DEFAULT 0 NOT NULL, "position" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT detection_modules_wave_valid CHECK (wave IN (1,2)));
CREATE UNIQUE INDEX "index_detection_modules_on_key" ON "detection_modules" ("key");
CREATE TABLE IF NOT EXISTS "account_modules" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "detection_module_id" integer NOT NULL, "enabled" boolean DEFAULT 1 NOT NULL, "cost_override" integer, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_e20f1ed9f6"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_6908a5075c"
FOREIGN KEY ("detection_module_id")
  REFERENCES "detection_modules" ("id")
);
CREATE INDEX "index_account_modules_on_account_id" ON "account_modules" ("account_id");
CREATE INDEX "index_account_modules_on_detection_module_id" ON "account_modules" ("detection_module_id");
CREATE UNIQUE INDEX "index_account_modules_uniqueness" ON "account_modules" ("account_id", "detection_module_id");
CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer, "role" varchar NOT NULL, "name" varchar NOT NULL, "email" varchar NOT NULL, "password_digest" varchar NOT NULL, "last_login_at" datetime(6), "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_61ac11da2b"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT users_role_valid CHECK (role IN ('super_admin','account_admin','member')), CONSTRAINT users_account_scoping_valid CHECK ((role = 'super_admin' AND account_id IS NULL) OR (role <> 'super_admin' AND account_id IS NOT NULL)));
CREATE INDEX "index_users_on_account_id" ON "users" ("account_id");
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");
CREATE TABLE IF NOT EXISTS "pixels" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "public_id" varchar NOT NULL, "name" varchar NOT NULL, "status" varchar DEFAULT 'active' NOT NULL, "allowed_origins" text DEFAULT '[]' NOT NULL, "signing_secret" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_1ebf141d64"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT pixels_status_valid CHECK (status IN ('active','paused','revoked')));
CREATE INDEX "index_pixels_on_account_id" ON "pixels" ("account_id");
CREATE UNIQUE INDEX "index_pixels_on_public_id" ON "pixels" ("public_id");
CREATE TABLE IF NOT EXISTS "capture_sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "pixel_id" integer NOT NULL, "public_id" varchar NOT NULL, "page_url" varchar, "referrer" varchar, "user_agent" varchar, "visit_ip" varchar, "submit_ip" varchar, "started_at" datetime(6) NOT NULL, "submitted_at" datetime(6), "interactions" text DEFAULT '[]' NOT NULL, "interaction_count" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_8abee97c2e"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_43e3bd2ece"
FOREIGN KEY ("pixel_id")
  REFERENCES "pixels" ("id")
);
CREATE INDEX "index_capture_sessions_on_account_id" ON "capture_sessions" ("account_id");
CREATE INDEX "index_capture_sessions_on_pixel_id" ON "capture_sessions" ("pixel_id");
CREATE UNIQUE INDEX "index_capture_sessions_on_public_id" ON "capture_sessions" ("public_id");
CREATE TABLE IF NOT EXISTS "leads" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "pixel_id" integer, "capture_session_id" integer, "public_id" varchar NOT NULL, "first_name" varchar, "last_name" varchar, "email" varchar, "phone" varchar, "email_normalized" varchar, "phone_normalized" varchar, "ip_address" varchar, "user_agent" varchar, "landing_page_url" varchar, "campaign" varchar, "form_dwell_ms" integer, "trusted_form_cert_url" varchar, "consent_checkbox" boolean, "captured_at" datetime(6) NOT NULL, "submitted_at" datetime(6), "origin" varchar DEFAULT 'pixel' NOT NULL, "expected_verdict_hint" varchar, "current_verification_run_id" bigint, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_5a793df820"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_738108cb58"
FOREIGN KEY ("pixel_id")
  REFERENCES "pixels" ("id")
, CONSTRAINT "fk_rails_546ecca7f8"
FOREIGN KEY ("capture_session_id")
  REFERENCES "capture_sessions" ("id")
, CONSTRAINT leads_origin_valid CHECK (origin IN ('seed','pixel')));
CREATE INDEX "index_leads_on_account_id" ON "leads" ("account_id");
CREATE INDEX "index_leads_on_pixel_id" ON "leads" ("pixel_id");
CREATE INDEX "index_leads_on_capture_session_id" ON "leads" ("capture_session_id");
CREATE UNIQUE INDEX "index_leads_on_public_id" ON "leads" ("public_id");
CREATE INDEX "index_leads_on_account_id_and_phone_normalized" ON "leads" ("account_id", "phone_normalized");
CREATE INDEX "index_leads_on_account_id_and_email_normalized" ON "leads" ("account_id", "email_normalized");
CREATE INDEX "index_leads_on_account_id_and_captured_at" ON "leads" ("account_id", "captured_at");
CREATE TABLE IF NOT EXISTS "crm_records" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "lead_id" integer, "crm_id" varchar NOT NULL, "first_name" varchar, "last_name" varchar, "email" varchar, "phone" varchar, "email_normalized" varchar, "phone_normalized" varchar, "source" varchar DEFAULT 'seed' NOT NULL, "recorded_at" datetime(6) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_884a604e2c"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_5da026ce47"
FOREIGN KEY ("lead_id")
  REFERENCES "leads" ("id")
, CONSTRAINT crm_records_source_valid CHECK (source IN ('seed','accepted_lead')));
CREATE INDEX "index_crm_records_on_account_id" ON "crm_records" ("account_id");
CREATE INDEX "index_crm_records_on_lead_id" ON "crm_records" ("lead_id");
CREATE UNIQUE INDEX "index_crm_records_on_account_id_and_crm_id" ON "crm_records" ("account_id", "crm_id");
CREATE INDEX "index_crm_records_on_account_id_and_phone_normalized" ON "crm_records" ("account_id", "phone_normalized");
CREATE INDEX "index_crm_records_on_account_id_and_email_normalized" ON "crm_records" ("account_id", "email_normalized");
CREATE TABLE IF NOT EXISTS "consensus_policies" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer, "name" varchar NOT NULL, "version" integer DEFAULT 1 NOT NULL, "active" boolean DEFAULT 1 NOT NULL, "rules" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_b4314c43a5"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
);
CREATE INDEX "index_consensus_policies_on_account_id" ON "consensus_policies" ("account_id");
CREATE UNIQUE INDEX "index_consensus_policies_on_account_id_and_version" ON "consensus_policies" ("account_id", "version");
CREATE TABLE IF NOT EXISTS "verification_runs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "lead_id" integer NOT NULL, "account_id" integer NOT NULL, "consensus_policy_id" integer NOT NULL, "status" varchar DEFAULT 'pending' NOT NULL, "verdict" varchar, "verdict_code" varchar, "risk_score" float, "confidence_score" float, "reasons" text DEFAULT '[]' NOT NULL, "coverage_applicable" integer DEFAULT 0 NOT NULL, "coverage_answered" integer DEFAULT 0 NOT NULL, "credits_estimated" integer DEFAULT 0 NOT NULL, "credits_charged" integer DEFAULT 0 NOT NULL, "short_circuited" boolean DEFAULT 0 NOT NULL, "attempt" integer DEFAULT 1 NOT NULL, "started_at" datetime(6), "completed_at" datetime(6), "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_1068edcd00"
FOREIGN KEY ("lead_id")
  REFERENCES "leads" ("id")
, CONSTRAINT "fk_rails_372c99aa5c"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_6cfa1285c2"
FOREIGN KEY ("consensus_policy_id")
  REFERENCES "consensus_policies" ("id")
, CONSTRAINT verification_runs_status_valid CHECK (status IN ('pending','wave_1','wave_2','finalizing','completed','halted_insufficient_credits','errored')), CONSTRAINT verification_runs_verdict_valid CHECK (verdict IS NULL OR verdict IN ('accept','review','reject')), CONSTRAINT verification_runs_verdict_requires_completion CHECK ((status = 'completed' AND verdict IS NOT NULL) OR (status <> 'completed' AND verdict IS NULL)));
CREATE INDEX "index_verification_runs_on_lead_id" ON "verification_runs" ("lead_id");
CREATE INDEX "index_verification_runs_on_account_id" ON "verification_runs" ("account_id");
CREATE INDEX "index_verification_runs_on_consensus_policy_id" ON "verification_runs" ("consensus_policy_id");
CREATE INDEX "index_verification_runs_on_account_id_and_created_at" ON "verification_runs" ("account_id", "created_at");
CREATE INDEX "index_verification_runs_on_account_id_and_verdict" ON "verification_runs" ("account_id", "verdict");
CREATE TABLE IF NOT EXISTS "layer_results" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "verification_run_id" integer NOT NULL, "account_id" integer NOT NULL, "detection_module_id" integer NOT NULL, "module_key" varchar NOT NULL, "state" varchar DEFAULT 'pending' NOT NULL, "signal" varchar, "hard_stop" boolean DEFAULT 0 NOT NULL, "risk_contribution" float DEFAULT 0.0 NOT NULL, "summary" varchar, "payload" text, "breakdown" text, "findings" text DEFAULT '[]' NOT NULL, "credits_charged" integer DEFAULT 0 NOT NULL, "wave" integer DEFAULT 2 NOT NULL, "error_class" varchar, "error_message" varchar, "started_at" datetime(6), "completed_at" datetime(6), "latency_ms" integer, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_b1b5c99682"
FOREIGN KEY ("verification_run_id")
  REFERENCES "verification_runs" ("id")
, CONSTRAINT "fk_rails_29b658b37b"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_79c5897d4f"
FOREIGN KEY ("detection_module_id")
  REFERENCES "detection_modules" ("id")
, CONSTRAINT layer_results_state_valid CHECK (state IN ('pending','completed','not_enabled','not_applicable','errored','skipped_insufficient_credits','skipped_hard_stop','timed_out')), CONSTRAINT layer_results_signal_valid CHECK (signal IS NULL OR signal IN ('pass','warn','fail','info')), CONSTRAINT layer_results_signal_requires_completion CHECK ((state = 'completed' AND signal IS NOT NULL) OR (state <> 'completed' AND signal IS NULL)), CONSTRAINT layer_results_charge_only_when_answered CHECK (state = 'completed' OR credits_charged = 0));
CREATE INDEX "index_layer_results_on_verification_run_id" ON "layer_results" ("verification_run_id");
CREATE INDEX "index_layer_results_on_account_id" ON "layer_results" ("account_id");
CREATE INDEX "index_layer_results_on_detection_module_id" ON "layer_results" ("detection_module_id");
CREATE UNIQUE INDEX "index_layer_results_on_verification_run_id_and_module_key" ON "layer_results" ("verification_run_id", "module_key");
CREATE TABLE IF NOT EXISTS "consent_certificates" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "verification_run_id" integer NOT NULL, "lead_id" integer NOT NULL, "account_id" integer NOT NULL, "serial" varchar NOT NULL, "schema_version" integer DEFAULT 1 NOT NULL, "issued_at" datetime(6) NOT NULL, "payload" text NOT NULL, "content_digest" varchar NOT NULL, "prev_digest" varchar, "chain_index" integer NOT NULL, "signature" text NOT NULL, "key_id" varchar NOT NULL, "algorithm" varchar NOT NULL, "revoked_at" datetime(6), "revocation_reason" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_8ecd901ff5"
FOREIGN KEY ("verification_run_id")
  REFERENCES "verification_runs" ("id")
, CONSTRAINT "fk_rails_a2af61e386"
FOREIGN KEY ("lead_id")
  REFERENCES "leads" ("id")
, CONSTRAINT "fk_rails_4d2ecad811"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
);
CREATE UNIQUE INDEX "index_consent_certificates_on_verification_run_id" ON "consent_certificates" ("verification_run_id");
CREATE INDEX "index_consent_certificates_on_lead_id" ON "consent_certificates" ("lead_id");
CREATE INDEX "index_consent_certificates_on_account_id" ON "consent_certificates" ("account_id");
CREATE UNIQUE INDEX "index_consent_certificates_on_serial" ON "consent_certificates" ("serial");
CREATE UNIQUE INDEX "index_consent_certificates_on_account_id_and_chain_index" ON "consent_certificates" ("account_id", "chain_index");
CREATE TABLE IF NOT EXISTS "credit_ledger_entries" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "verification_run_id" integer, "layer_result_id" integer, "entry_type" varchar NOT NULL, "module_key" varchar, "amount" integer NOT NULL, "balance_after" integer NOT NULL, "idempotency_key" varchar NOT NULL, "description" varchar, "occurred_at" datetime(6) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_f9ce52e692"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_375344ef24"
FOREIGN KEY ("verification_run_id")
  REFERENCES "verification_runs" ("id")
, CONSTRAINT "fk_rails_a47d29c8cf"
FOREIGN KEY ("layer_result_id")
  REFERENCES "layer_results" ("id")
, CONSTRAINT credit_ledger_entries_type_valid CHECK (entry_type IN ('debit','refund','allowance_grant','historical_rollup','adjustment')), CONSTRAINT credit_ledger_entries_amount_non_zero CHECK (amount <> 0));
CREATE INDEX "index_credit_ledger_entries_on_account_id" ON "credit_ledger_entries" ("account_id");
CREATE INDEX "index_credit_ledger_entries_on_verification_run_id" ON "credit_ledger_entries" ("verification_run_id");
CREATE INDEX "index_credit_ledger_entries_on_layer_result_id" ON "credit_ledger_entries" ("layer_result_id");
CREATE UNIQUE INDEX "index_credit_ledger_entries_on_idempotency_key" ON "credit_ledger_entries" ("idempotency_key");
CREATE INDEX "index_credit_ledger_entries_on_account_id_and_occurred_at" ON "credit_ledger_entries" ("account_id", "occurred_at");
CREATE TRIGGER consent_certificates_immutable_update
BEFORE UPDATE ON consent_certificates
WHEN OLD.payload        <> NEW.payload
  OR OLD.content_digest <> NEW.content_digest
  OR OLD.signature      <> NEW.signature
  OR OLD.serial         <> NEW.serial
  OR OLD.chain_index    <> NEW.chain_index
  OR IFNULL(OLD.prev_digest, '') <> IFNULL(NEW.prev_digest, '')
BEGIN
  SELECT RAISE(ABORT, 'consent certificates are immutable once issued');
END;
CREATE TRIGGER credit_ledger_entries_immutable_update
BEFORE UPDATE ON credit_ledger_entries
BEGIN
  SELECT RAISE(ABORT, 'the credit ledger is append-only');
END;
CREATE TRIGGER credit_ledger_entries_immutable_delete
BEFORE DELETE ON credit_ledger_entries
BEGIN
  SELECT RAISE(ABORT, 'the credit ledger is append-only');
END;
CREATE TABLE IF NOT EXISTS "activity_events" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "lead_id" integer, "verification_run_id" integer, "capture_session_id" integer, "pixel_id" integer, "kind" varchar NOT NULL, "payload" text DEFAULT '{}' NOT NULL, "occurred_at" datetime(6) NOT NULL, "created_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_8676161dee"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
, CONSTRAINT "fk_rails_66a102ee5b"
FOREIGN KEY ("lead_id")
  REFERENCES "leads" ("id")
, CONSTRAINT "fk_rails_9cd793b78b"
FOREIGN KEY ("verification_run_id")
  REFERENCES "verification_runs" ("id")
, CONSTRAINT "fk_rails_2c2dbb47f5"
FOREIGN KEY ("capture_session_id")
  REFERENCES "capture_sessions" ("id")
, CONSTRAINT "fk_rails_2117655422"
FOREIGN KEY ("pixel_id")
  REFERENCES "pixels" ("id")
);
CREATE INDEX "index_activity_events_on_account_id" ON "activity_events" ("account_id");
CREATE INDEX "index_activity_events_on_lead_id" ON "activity_events" ("lead_id");
CREATE INDEX "index_activity_events_on_verification_run_id" ON "activity_events" ("verification_run_id");
CREATE INDEX "index_activity_events_on_capture_session_id" ON "activity_events" ("capture_session_id");
CREATE INDEX "index_activity_events_on_pixel_id" ON "activity_events" ("pixel_id");
CREATE INDEX "index_activity_events_on_lead_id_and_id" ON "activity_events" ("lead_id", "id");
CREATE INDEX "index_activity_events_on_account_id_and_id" ON "activity_events" ("account_id", "id");
CREATE TABLE IF NOT EXISTS "provider_fixtures" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "provider_key" varchar NOT NULL, "lead_public_id" varchar NOT NULL, "payload" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_provider_fixtures_on_provider_key_and_lead_public_id" ON "provider_fixtures" ("provider_key", "lead_public_id");
CREATE TABLE IF NOT EXISTS "provider_subjects" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "lead_public_id" varchar NOT NULL, "email_normalized" varchar, "phone_normalized" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_provider_subjects_on_lead_public_id" ON "provider_subjects" ("lead_public_id");
CREATE INDEX "index_provider_subjects_on_email_normalized" ON "provider_subjects" ("email_normalized");
CREATE INDEX "index_provider_subjects_on_phone_normalized" ON "provider_subjects" ("phone_normalized");
CREATE TABLE IF NOT EXISTS "admin_access_logs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "account_id" integer, "action" varchar NOT NULL, "path" varchar, "ip" varchar, "occurred_at" datetime(6) NOT NULL, "created_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_580af68ebd"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
, CONSTRAINT "fk_rails_e43623fc2c"
FOREIGN KEY ("account_id")
  REFERENCES "accounts" ("id")
);
CREATE INDEX "index_admin_access_logs_on_user_id" ON "admin_access_logs" ("user_id");
CREATE INDEX "index_admin_access_logs_on_account_id" ON "admin_access_logs" ("account_id");
CREATE INDEX "index_admin_access_logs_on_user_id_and_occurred_at" ON "admin_access_logs" ("user_id", "occurred_at");
INSERT INTO "schema_migrations" (version) VALUES
('20260903000006'),
('20260903000005'),
('20260903000004'),
('20260903000003'),
('20260903000002'),
('20260903000001');

