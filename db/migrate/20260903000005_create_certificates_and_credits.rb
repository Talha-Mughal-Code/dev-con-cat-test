class CreateCertificatesAndCredits < ActiveRecord::Migration[7.2]
  def change
    create_table :consent_certificates do |t|
      t.references :verification_run, null: false, foreign_key: true, index: { unique: true }
      t.references :lead,             null: false, foreign_key: true
      t.references :account,          null: false, foreign_key: true
      t.string   :serial,         null: false
      t.integer  :schema_version, null: false, default: 1
      t.datetime :issued_at,      null: false
      # The exact canonical JSON that was signed. Stored verbatim so
      # verification never has to re-derive it from live (mutable) rows.
      t.text     :payload,        null: false
      t.string   :content_digest, null: false
      # Per-account hash chain: each certificate commits to the digest of the
      # account's previous one, so a deleted or reordered certificate is
      # detectable, not just a tampered one.
      t.string   :prev_digest
      t.integer  :chain_index,    null: false
      t.text     :signature,      null: false
      t.string   :key_id,         null: false
      t.string   :algorithm,      null: false
      t.datetime :revoked_at
      t.string   :revocation_reason
      t.timestamps
    end
    add_index :consent_certificates, :serial, unique: true
    add_index :consent_certificates, %i[account_id chain_index], unique: true

    # Append-only credit ledger. This is the source of truth for billing;
    # accounts.credits_consumed is a cache of its sum for the current cycle.
    create_table :credit_ledger_entries do |t|
      t.references :account,          null: false, foreign_key: true
      t.references :verification_run, null: true,  foreign_key: true
      t.references :layer_result,     null: true,  foreign_key: true
      t.string  :entry_type, null: false
      t.string  :module_key
      # Signed: negative consumes credits, positive grants or refunds them.
      t.integer :amount,        null: false
      t.integer :balance_after, null: false
      # Makes debits idempotent. Solid Queue retries a failed layer job; the
      # unique index is what guarantees the buyer is not charged twice for it.
      t.string  :idempotency_key, null: false
      t.string  :description
      t.datetime :occurred_at, null: false
      t.timestamps

      t.check_constraint "entry_type IN ('debit','refund','allowance_grant'," \
                         "'historical_rollup','adjustment')",
                         name: "credit_ledger_entries_type_valid"
      t.check_constraint "amount <> 0", name: "credit_ledger_entries_amount_non_zero"
    end
    add_index :credit_ledger_entries, :idempotency_key, unique: true
    add_index :credit_ledger_entries, %i[account_id occurred_at]

    # Storage-level immutability. Application-level `readonly?` protects against
    # our own mistakes; these triggers mean even a stray console UPDATE cannot
    # rewrite issued evidence. Revocation is an additive field, so it stays
    # permitted while the signed body does not.
    reversible do |dir|
      dir.up do
        execute <<~SQL
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
        SQL
        execute <<~SQL
          CREATE TRIGGER credit_ledger_entries_immutable_update
          BEFORE UPDATE ON credit_ledger_entries
          BEGIN
            SELECT RAISE(ABORT, 'the credit ledger is append-only');
          END;
        SQL
        execute <<~SQL
          CREATE TRIGGER credit_ledger_entries_immutable_delete
          BEFORE DELETE ON credit_ledger_entries
          BEGIN
            SELECT RAISE(ABORT, 'the credit ledger is append-only');
          END;
        SQL
      end
      dir.down do
        execute "DROP TRIGGER IF EXISTS consent_certificates_immutable_update"
        execute "DROP TRIGGER IF EXISTS credit_ledger_entries_immutable_update"
        execute "DROP TRIGGER IF EXISTS credit_ledger_entries_immutable_delete"
      end
    end
  end
end
