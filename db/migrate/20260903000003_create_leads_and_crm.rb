class CreateLeadsAndCrm < ActiveRecord::Migration[7.2]
  def change
    create_table :leads do |t|
      t.references :account,         null: false, foreign_key: true
      t.references :pixel,           null: true,  foreign_key: true
      t.references :capture_session, null: true,  foreign_key: true
      t.string :public_id, null: false            # L-1001

      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      # Normalised forms are what duplicate detection and CRM matching compare.
      # Storing them means matching is an indexed equality lookup rather than a
      # scan with per-row normalisation.
      t.string :email_normalized
      t.string :phone_normalized

      t.string  :ip_address
      t.string  :user_agent
      t.string  :landing_page_url
      t.string  :campaign
      t.integer :form_dwell_ms
      t.string  :trusted_form_cert_url
      # Tri-state on purpose: NULL means the checkbox was never captured
      # (seeded leads predate the pixel), false means it was captured and
      # left unchecked. Those are very different consent stories.
      t.boolean :consent_checkbox

      t.datetime :captured_at,  null: false
      t.datetime :submitted_at
      t.string   :origin, null: false, default: "pixel"

      # SEED DATA ONLY. mock-data/leads.json ships an `expected_verdict` hint.
      # It is stored here so the test suite can use it as an oracle, and it is
      # deliberately unreachable from the engine - see
      # test/engine/seed_lead_verdicts_test.rb and SOLUTION.md.
      t.string :expected_verdict_hint

      t.bigint :current_verification_run_id
      t.timestamps

      t.check_constraint "origin IN ('seed','pixel')", name: "leads_origin_valid"
    end
    add_index :leads, :public_id, unique: true
    add_index :leads, %i[account_id phone_normalized]
    add_index :leads, %i[account_id email_normalized]
    add_index :leads, %i[account_id captured_at]

    # The buyer's own CRM. Duplicate detection reads this; accepted leads are
    # written back into it so the check stays live rather than frozen at seed.
    create_table :crm_records do |t|
      t.references :account, null: false, foreign_key: true
      t.references :lead,    null: true,  foreign_key: true
      t.string :crm_id, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.string :email_normalized
      t.string :phone_normalized
      t.string :source, null: false, default: "seed"
      t.datetime :recorded_at, null: false
      t.timestamps

      t.check_constraint "source IN ('seed','accepted_lead')", name: "crm_records_source_valid"
    end
    add_index :crm_records, %i[account_id crm_id], unique: true
    add_index :crm_records, %i[account_id phone_normalized]
    add_index :crm_records, %i[account_id email_normalized]
  end
end
