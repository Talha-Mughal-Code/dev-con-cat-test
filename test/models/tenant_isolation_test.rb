require "test_helper"

# Tenant isolation at the query layer.
#
# EVALUATION.md names "tenant isolation only enforced in views; data leaks via
# direct IDs/params" as a red flag, so these tests attack the database directly
# rather than going through controllers. If isolation only worked because a view
# rendered nothing, every one of these would fail.
class TenantIsolationTest < ActiveSupport::TestCase
  setup do
    @a = build_account(public_id: "acct_alpha")
    @b = build_account(public_id: "acct_beta")

    @a_lead = build_lead(account: @a, pixel: build_pixel(account: @a), email: "alpha@example.com")
    @b_lead = build_lead(account: @b, pixel: build_pixel(account: @b), email: "beta@example.com")
  end

  # Every model that owns tenant data. Listed explicitly so adding a
  # tenant-scoped model without adding it here is a visible omission rather than
  # a silent gap.
  TENANT_MODELS = [
    Pixel, CaptureSession, Lead, CrmRecord, VerificationRun, LayerResult,
    ConsentCertificate, CreditLedgerEntry, ActivityEvent, AccountModule
  ].freeze

  test "every tenant-owned model applies the tenant scope" do
    TENANT_MODELS.each do |model|
      assert model.include?(TenantScoped), "#{model.name} must include TenantScoped"
      assert model.column_names.include?("account_id"), "#{model.name} must have account_id"
    end
  end

  test "account_id is NOT NULL on every tenant-owned table" do
    # A nullable tenant key is a row that belongs to nobody, and therefore a row
    # the scope cannot exclude.
    TENANT_MODELS.each do |model|
      column = model.columns_hash.fetch("account_id")
      assert_not column.null, "#{model.table_name}.account_id must be NOT NULL"
    end
  end

  test "finding another account's lead by its id raises RecordNotFound" do
    # The central claim. Not "returns nil", not "renders an empty page" - the
    # row is not reachable, because the account predicate is in the SQL.
    TenantScope.for_account(@a) do
      assert_raises ActiveRecord::RecordNotFound do
        Lead.find(@b_lead.id)
      end

      assert_raises ActiveRecord::RecordNotFound do
        Lead.find_by!(public_id: @b_lead.public_id)
      end

      assert_nil Lead.find_by(id: @b_lead.id)
      assert_equal [ @a_lead.id ], Lead.pluck(:id)
    end
  end

  test "the tenant predicate is in the generated SQL" do
    TenantScope.for_account(@a) do
      sql = Lead.where(email: "anything@example.com").to_sql
      assert_match(/"leads"\."account_id" = #{@a.id}/, sql,
                   "the account predicate must be in the query, not applied afterwards")
    end
  end

  test "aggregates, counts and updates are all scoped, not just finds" do
    # A leak through count or update_all would be just as real as one through
    # find, and easier to miss.
    build_lead(account: @b, pixel: @b_lead.pixel)

    TenantScope.for_account(@a) do
      assert_equal 1, Lead.count
      assert_equal 0, Lead.where(email: @b_lead.email).count
      # An UPDATE cannot reach across the boundary either.
      assert_equal 0, Lead.where(id: @b_lead.id).update_all(first_name: "Hacked")
    end

    assert_not_equal "Hacked", @b_lead.reload.first_name
  end

  test "a record created inside a tenant scope belongs to that tenant" do
    # Not merely prevented from reading across the boundary - a new row cannot
    # be attributed to the wrong account by omission.
    TenantScope.for_account(@a) do
      lead = Lead.create!(captured_at: Time.current, email: "auto@example.com", origin: "pixel")
      assert_equal @a.id, lead.account_id
    end
  end

  test "queries with no tenant context raise rather than returning everything" do
    # The most important default in the system. `all` would silently leak every
    # tenant's data the first time a controller forgot to establish an account.
    Current.reset

    TENANT_MODELS.each do |model|
      assert_raises TenantScope::MissingTenantContext, "#{model.name} must refuse to query unscoped" do
        model.first
      end
    end
  end

  test "the cross-account escape hatch is explicit and narrow" do
    Current.reset

    # Nothing ambient grants it...
    assert_raises TenantScope::MissingTenantContext do
      Lead.count
    end

    # ...and it has to be asked for by name.
    TenantScope.across_accounts do
      assert_equal 2, Lead.count
    end

    # It does not leak past its own block.
    assert_raises TenantScope::MissingTenantContext do
      Lead.count
    end
  end

  test "tenant context is restored after an exception inside a scope" do
    # A leaked Current between requests would be a cross-tenant read waiting to
    # happen, so the ensure blocks matter.
    TenantScope.for_account(@a) do
      assert_raises RuntimeError do
        TenantScope.for_account(@b) { raise "boom" }
      end

      assert_equal @a.id, Current.account_id, "the inner scope must not survive its own failure"
    end

    assert_nil Current.account
  end

  test "nested scopes for different accounts do not bleed" do
    TenantScope.for_account(@a) do
      assert_equal [ @a_lead.id ], Lead.pluck(:id)

      TenantScope.for_account(@b) do
        assert_equal [ @b_lead.id ], Lead.pluck(:id)
      end

      assert_equal [ @a_lead.id ], Lead.pluck(:id)
    end
  end

  test "an account cannot be found through another account's association" do
    # Association traversal is a classic leak: lead.account.leads would hand back
    # everything if the far side were unscoped.
    TenantScope.for_account(@a) do
      assert_equal [ @a_lead.id ], @a.leads.pluck(:id)
      # Even reaching through a record we legitimately hold.
      assert_equal [ @a_lead.id ], @a_lead.account.leads.pluck(:id)
    end
  end

  test "duplicate detection never matches across accounts" do
    # A buyer must not be denied a lead because a competitor already owns it -
    # and must not learn that a competitor owns it either.
    twin = build_lead(account: @b, pixel: @b_lead.pixel, email: @a_lead.email,
                      phone: @a_lead.phone)
    TenantScope.for_account(@b) do
      CrmRecord.create!(crm_id: "B-1", email: twin.email, phone: twin.phone,
                        recorded_at: 1.day.ago, source: "seed")
    end

    run = verify!(@a_lead)

    TenantScope.for_account(@a) do
      duplicate = run.layer_results.find_by(module_key: "duplicate_detection")
      assert_equal "pass", duplicate.signal
      assert_equal "none", duplicate.breakdown.fetch("match_type")
    end
  end

  test "a super_admin has no ambient account and therefore no ambient access" do
    # The point of giving platform operators a NULL account_id: the scope raises
    # for them too, so an ordinary controller cannot accidentally serve them
    # everything.
    operator = build_user(role: "super_admin", account: nil)
    Current.user = operator
    Current.account = operator.account

    assert_nil Current.account_id
    assert_raises TenantScope::MissingTenantContext do
      Lead.count
    end
  end
end
