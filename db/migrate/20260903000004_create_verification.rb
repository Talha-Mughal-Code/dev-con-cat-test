class CreateVerification < ActiveRecord::Migration[7.2]
  def change
    # Weights, thresholds and hard-stop rules live in the database as data, not
    # in Ruby, so a buyer can tune the engine (e.g. promote "suspected
    # litigator" to a hard stop) without a deploy. account_id NULL is the
    # platform default that every account inherits until it overrides.
    create_table :consensus_policies do |t|
      t.references :account, null: true, foreign_key: true
      t.string  :name,    null: false
      t.integer :version, null: false, default: 1
      t.boolean :active,  null: false, default: true
      t.text    :rules,   null: false
      t.timestamps
    end
    add_index :consensus_policies, %i[account_id version], unique: true

    # A run is one evaluation of one lead under one policy version. It is a
    # separate entity from the lead because a lead can legitimately be
    # re-verified: after a vendor outage, after a policy change, or after the
    # account tops up credits following a halted run. The verdict belongs to the
    # run, never to the lead.
    create_table :verification_runs do |t|
      t.references :lead,              null: false, foreign_key: true
      t.references :account,           null: false, foreign_key: true
      t.references :consensus_policy,  null: false, foreign_key: true
      t.string :status,  null: false, default: "pending"
      t.string :verdict                       # NULL until a verdict is reached
      t.string :verdict_code                  # machine-readable primary reason
      t.float  :risk_score
      t.float  :confidence_score
      t.text   :reasons, null: false, default: "[]"
      # Coverage: how many of the layers that could have spoken actually did.
      # Surfaced on the certificate so a buyer knows how complete the check was.
      t.integer :coverage_applicable, null: false, default: 0
      t.integer :coverage_answered,   null: false, default: 0
      t.integer :credits_estimated,   null: false, default: 0
      t.integer :credits_charged,     null: false, default: 0
      t.boolean :short_circuited,     null: false, default: false
      t.integer :attempt,             null: false, default: 1
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps

      t.check_constraint "status IN ('pending','running','completed'," \
                         "'halted_insufficient_credits','errored')",
                         name: "verification_runs_status_valid"
      t.check_constraint "verdict IS NULL OR verdict IN ('accept','review','reject')",
                         name: "verification_runs_verdict_valid"
      # A run may only carry a verdict once it has completed. This is what stops
      # a halted or errored run from ever looking like an ACCEPT.
      t.check_constraint "(status = 'completed' AND verdict IS NOT NULL) OR " \
                         "(status <> 'completed' AND verdict IS NULL)",
                         name: "verification_runs_verdict_requires_completion"
    end
    add_index :verification_runs, %i[account_id created_at]
    add_index :verification_runs, %i[account_id verdict]

    create_table :layer_results do |t|
      t.references :verification_run, null: false, foreign_key: true
      t.references :account,          null: false, foreign_key: true
      t.references :detection_module, null: false, foreign_key: true
      t.string :module_key, null: false

      # STATE answers "did this layer get to speak?" - the three states the
      # brief calls out (not_enabled / not_applicable / answered) plus the
      # failure modes, kept deliberately distinct from the verdict itself.
      t.string :state,  null: false, default: "pending"
      # SIGNAL answers "what did it say?" and is NULL unless state = completed.
      t.string :signal
      t.boolean :hard_stop,       null: false, default: false
      t.float   :risk_contribution, null: false, default: 0.0
      t.string  :summary
      t.text    :payload            # raw vendor response, retained as evidence
      t.text    :breakdown          # per-sub-provider detail for consensus layers
      t.integer :credits_charged, null: false, default: 0
      t.integer :wave,            null: false, default: 2
      t.string  :error_class
      t.string  :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.integer  :latency_ms
      t.timestamps

      t.check_constraint "state IN ('pending','completed','not_enabled'," \
                         "'not_applicable','errored','skipped_insufficient_credits','timed_out')",
                         name: "layer_results_state_valid"
      t.check_constraint "signal IS NULL OR signal IN ('pass','warn','fail','info')",
                         name: "layer_results_signal_valid"
      # The core of the three-state model: only a layer that actually ran may
      # carry a signal. not_enabled and not_applicable can never masquerade as
      # a pass.
      t.check_constraint "(state = 'completed' AND signal IS NOT NULL) OR " \
                         "(state <> 'completed' AND signal IS NULL)",
                         name: "layer_results_signal_requires_completion"
      t.check_constraint "state = 'completed' OR credits_charged = 0",
                         name: "layer_results_charge_only_when_answered"
    end
    add_index :layer_results, %i[verification_run_id module_key], unique: true
  end
end
