class CreateUsersAndPixels < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      # NULL account_id means a platform operator (super_admin). Tenant users
      # always have one, enforced by a check constraint below, so a mis-seeded
      # user can never become an accidental cross-tenant reader.
      t.references :account, null: true, foreign_key: true
      t.string :role,            null: false
      t.string :name,            null: false
      t.string :email,           null: false
      t.string :password_digest, null: false
      t.datetime :last_login_at
      t.timestamps

      t.check_constraint "role IN ('super_admin','account_admin','member')", name: "users_role_valid"
      t.check_constraint "(role = 'super_admin' AND account_id IS NULL) OR " \
                         "(role <> 'super_admin' AND account_id IS NOT NULL)",
                         name: "users_account_scoping_valid"
    end
    add_index :users, :email, unique: true

    create_table :pixels do |t|
      t.references :account, null: false, foreign_key: true
      t.string :public_id, null: false            # px_9f2a01 - public, appears in page source
      t.string :name,      null: false
      t.string :status,    null: false, default: "active"
      # Origin allowlist. The pixel id is public, so this is what actually stops
      # someone POSTing leads into another account's pixel.
      t.text   :allowed_origins, null: false, default: "[]"
      # Per-pixel HMAC key used to sign the short-lived capture-session token
      # that /visit issues and /leads requires. Rotating or revoking a pixel
      # therefore invalidates its in-flight sessions.
      t.string :signing_secret, null: false
      t.timestamps

      t.check_constraint "status IN ('active','paused','revoked')", name: "pixels_status_valid"
    end
    add_index :pixels, :public_id, unique: true

    create_table :capture_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :pixel,   null: false, foreign_key: true
      t.string :public_id,   null: false
      t.string :page_url
      t.string :referrer
      t.string :user_agent
      # The two IPs the VPN layer compares: where the visitor browsed from vs.
      # where they submitted from.
      t.string :visit_ip
      t.string :submit_ip
      t.datetime :started_at,   null: false
      t.datetime :submitted_at
      # Field focus/blur/change telemetry, kept as a JSON document because it is
      # written once as evidence and never queried field-by-field.
      t.text :interactions, null: false, default: "[]"
      t.integer :interaction_count, null: false, default: 0
      t.timestamps
    end
    add_index :capture_sessions, :public_id, unique: true
  end
end
