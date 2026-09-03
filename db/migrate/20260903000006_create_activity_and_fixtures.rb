class CreateActivityAndFixtures < ActiveRecord::Migration[7.2]
  def change
    # One append-only stream that serves three purposes: the account activity
    # timeline, the audit trail, and the real-time feed the landing page tails.
    # The primary key doubles as the SSE cursor (Last-Event-ID), which is why
    # this is a single ordered table rather than per-purpose tables.
    create_table :activity_events do |t|
      t.references :account,           null: false, foreign_key: true
      t.references :lead,              null: true,  foreign_key: true
      t.references :verification_run,  null: true,  foreign_key: true
      t.references :capture_session,   null: true,  foreign_key: true
      t.references :pixel,             null: true,  foreign_key: true
      t.string   :kind,    null: false
      t.text     :payload, null: false, default: "{}"
      t.datetime :occurred_at, null: false
      t.datetime :created_at,  null: false
    end
    add_index :activity_events, %i[lead_id id]
    add_index :activity_events, %i[account_id id]

    # The mock vendor responses from mock-data/providers/*.json, loaded at seed
    # time. Reading them from a table rather than the filesystem at request time
    # means the vendor gateway has the same shape it would have in production:
    # an I/O call that can be slow, absent, or fail.
    create_table :provider_fixtures do |t|
      t.string :provider_key,   null: false
      t.string :lead_public_id, null: false
      t.text   :payload,        null: false
      t.timestamps
    end
    add_index :provider_fixtures, %i[provider_key lead_public_id], unique: true

    # The mock vendors' own subject index: which contact details each seeded
    # fixture describes.
    #
    # This exists so the vendor gateway never has to read Lead rows to recognise
    # a contact. A real vendor's database is global - Blacklist Alliance knows a
    # litigator's phone number regardless of which buyer is asking - so
    # modelling it as tenant data would be wrong twice over: it would make the
    # lookup account-scoped (and therefore useless), and it would have one
    # account's leads influencing another's verdicts through a back door.
    #
    # Vendor reference data, keyed by contact details, exactly as the real thing
    # would be.
    create_table :provider_subjects do |t|
      t.string :lead_public_id, null: false
      t.string :email_normalized
      t.string :phone_normalized
      t.timestamps
    end
    add_index :provider_subjects, :lead_public_id, unique: true
    add_index :provider_subjects, :email_normalized
    add_index :provider_subjects, :phone_normalized

    # Every cross-account read by a platform operator is recorded. super_admin
    # is a real privilege escalation, so it leaves a trail.
    create_table :admin_access_logs do |t|
      t.references :user,    null: false, foreign_key: true
      t.references :account, null: true,  foreign_key: true
      t.string :action, null: false
      t.string :path
      t.string :ip
      t.datetime :occurred_at, null: false
      t.datetime :created_at,  null: false
    end
    add_index :admin_access_logs, %i[user_id occurred_at]
  end
end
