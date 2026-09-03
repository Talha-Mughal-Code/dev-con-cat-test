class CreateAccountsAndModules < ActiveRecord::Migration[7.2]
  def change
    create_table :accounts do |t|
      # public_id is the stable, externally-visible identifier (acct_solarpro).
      # Internal integer PKs are never exposed in URLs or the pixel payload.
      t.string  :public_id,                null: false
      t.string  :company_name,             null: false
      t.string  :plan,                     null: false, default: "starter"
      t.string  :status,                   null: false, default: "active"
      t.integer :monthly_credit_allowance, null: false, default: 0
      # Cached counter. The credit_ledger_entries table is the source of truth;
      # this column exists so we can check affordability in a single atomic
      # UPDATE without summing the ledger. A reconciliation test proves the two
      # never disagree.
      t.integer :credits_consumed,         null: false, default: 0
      t.date    :cycle_start,              null: false
      t.date    :cycle_end,                null: false
      # Seeded burn rate, used for "days until dry" before enough ledger
      # history accumulates to compute a trailing average.
      t.integer :baseline_daily_burn,      null: false, default: 0
      t.string  :billing_contact
      # Per-account engine tuning that isn't part of the scoring policy itself.
      t.boolean :short_circuit_on_hard_stop, null: false, default: true
      t.timestamps

      t.check_constraint "plan IN ('starter','growth','enterprise')", name: "accounts_plan_valid"
      t.check_constraint "status IN ('active','past_due','suspended')", name: "accounts_status_valid"
      t.check_constraint "credits_consumed >= 0", name: "accounts_credits_consumed_non_negative"
    end
    add_index :accounts, :public_id, unique: true

    # Catalog of detection layers available on the platform.
    create_table :detection_modules do |t|
      t.string  :key,                     null: false
      t.string  :name,                    null: false
      t.string  :question                              # the question the layer answers
      t.integer :default_cost_in_credits, null: false, default: 1
      # Wave 1 = cheap, dispositive checks that can hard-stop a lead. Wave 2 =
      # the weighted signals. Running wave 1 first lets a hard stop short
      # circuit the expensive layers and save the buyer credits.
      t.integer :wave,                    null: false, default: 2
      # When a consent-critical layer is enabled but unavailable we fail closed
      # (cap at REVIEW); other layers fail open with reduced coverage.
      t.boolean :consent_critical,        null: false, default: false
      t.boolean :hard_stop_capable,       null: false, default: false
      t.boolean :in_development,          null: false, default: false
      t.integer :position,                null: false, default: 0
      t.timestamps

      t.check_constraint "wave IN (1,2)", name: "detection_modules_wave_valid"
    end
    add_index :detection_modules, :key, unique: true

    # Which layers an account pays for. A join table rather than a serialised
    # array on accounts so that enablement is auditable and per-account pricing
    # can override the catalog default.
    create_table :account_modules do |t|
      t.references :account,          null: false, foreign_key: true
      t.references :detection_module, null: false, foreign_key: true
      t.boolean :enabled,             null: false, default: true
      t.integer :cost_override
      t.timestamps
    end
    add_index :account_modules, %i[account_id detection_module_id], unique: true,
              name: "index_account_modules_uniqueness"
  end
end
