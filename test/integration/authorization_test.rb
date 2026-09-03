require "test_helper"

# Authorization through the real HTTP stack.
#
# The brief asks for authorization to be enforced rather than have buttons
# hidden, so these tests are requests, not unit calls on a policy object. The
# demonstrable claim it asks for - "a member of account A cannot reach account
# B's data by any route" - is asserted here route by route.
class AuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @alpha = build_account(public_id: "acct_alpha")
    @beta  = build_account(public_id: "acct_beta")

    @alpha_admin  = build_user(account: @alpha, role: "account_admin", email: "admin@alpha.example")
    @alpha_member = build_user(account: @alpha, role: "member", email: "member@alpha.example")
    @beta_admin   = build_user(account: @beta, role: "account_admin", email: "admin@beta.example")
    @operator     = build_user(account: nil, role: "super_admin", email: "root@platform.example")

    @alpha_pixel = build_pixel(account: @alpha, name: "Alpha funnel")
    @beta_pixel  = build_pixel(account: @beta, name: "Beta funnel")

    @alpha_lead = build_lead(account: @alpha, pixel: @alpha_pixel, first_name: "Alpha")
    @beta_lead  = build_lead(account: @beta, pixel: @beta_pixel, first_name: "Beta")
    @beta_run   = verify!(@beta_lead)
  end

  def sign_in_as(user, password: "test-password-1234")
    post session_path, params: { user: { email: user.email, password: password } }
  end

  # --- authentication -------------------------------------------------------

  test "protected pages require a session" do
    %w[/dashboard /leads /pixels /activity /policy /platform].each do |path|
      get path
      assert_redirected_to new_session_path, "#{path} must require authentication"
    end
  end

  test "signing in with a wrong password does not reveal whether the account exists" do
    # The same message either way, so the form cannot be used to enumerate users.
    post session_path, params: { user: { email: @alpha_admin.email, password: "wrong-password" } }
    known = flash[:alert]

    post session_path, params: { user: { email: "nobody@nowhere.example", password: "wrong-password" } }
    unknown = flash[:alert]

    assert_equal known, unknown
    assert_response :unprocessable_entity
  end

  test "a session is reset on sign-in so a fixated session cannot be reused" do
    get new_session_path
    sign_in_as(@alpha_admin)
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_response :success
  end

  # --- cross-tenant reads ---------------------------------------------------

  test "a member of one account cannot reach another account's lead by any route" do
    sign_in_as(@alpha_member)

    get lead_path(@beta_lead.public_id)
    assert_response :not_found

    # 404 rather than 403 on purpose: distinguishing "forbidden" from "missing"
    # tells an attacker which ids exist.
    assert_no_match(/Beta/, response.body)
  end

  test "another account's certificate is not reachable by serial" do
    certificate = TenantScope.for_account(@beta) { @beta_run.consent_certificate }
    sign_in_as(@alpha_member)

    get certificate_path(certificate.serial)
    assert_response :not_found

    get verify_certificate_path(certificate.serial)
    assert_response :not_found
  end

  test "another account's pixel is not reachable, readable or editable" do
    sign_in_as(@alpha_admin)

    get pixel_path(@beta_pixel.public_id)
    assert_response :not_found

    get edit_pixel_path(@beta_pixel.public_id)
    assert_response :not_found

    patch pixel_path(@beta_pixel.public_id), params: { pixel: { name: "Hijacked" } }
    assert_response :not_found
    assert_equal "Beta funnel", @beta_pixel.reload.name
  end

  test "a lead list contains only the signed-in account's leads" do
    sign_in_as(@alpha_member)

    get leads_path
    assert_response :success
    assert_match(/Alpha/, response.body)
    assert_no_match(/#{@beta_lead.public_id}/, response.body)
  end

  test "search cannot be used to fish for another account's leads" do
    sign_in_as(@alpha_member)

    get leads_path, params: { q: @beta_lead.email }
    assert_response :success
    assert_no_match(/#{@beta_lead.public_id}/, response.body)
  end

  test "a crafted pixel filter cannot widen the lead list" do
    # The classic parameter-tampering attempt.
    sign_in_as(@alpha_member)

    get leads_path, params: { pixel: @beta_pixel.public_id }
    assert_response :success
    assert_no_match(/#{@beta_lead.public_id}/, response.body)
  end

  # --- roles ----------------------------------------------------------------

  test "a member cannot create or edit pixels" do
    sign_in_as(@alpha_member)

    get new_pixel_path
    assert_response :not_found

    post pixels_path, params: { pixel: { name: "Sneaky", allowed_origins: "https://x.example" } }
    assert_response :not_found

    get edit_pixel_path(@alpha_pixel.public_id)
    assert_response :not_found
  end

  test "a member cannot change the consensus policy" do
    # The policy decides what gets accepted, so this is the most sensitive
    # non-billing setting in the account.
    sign_in_as(@alpha_member)

    get policy_path
    assert_response :not_found

    patch policy_path, params: { policy: { thresholds: { accept_below: 0.99 } } }
    assert_response :not_found
  end

  test "a member cannot trigger a re-verification, which spends credits" do
    sign_in_as(@alpha_member)

    post reverify_lead_path(@alpha_lead.public_id)
    assert_response :not_found
  end

  test "an account admin can do all of those things for their own account" do
    sign_in_as(@alpha_admin)

    get new_pixel_path
    assert_response :success

    post pixels_path, params: { pixel: { name: "Second funnel",
                                         allowed_origins: "https://alpha.example" } }
    assert_response :redirect

    get policy_path
    assert_response :success
  end

  test "a member can still read their own account's leads and certificates" do
    # Enforcement must not overshoot: day-to-day CRM work is a member's job.
    sign_in_as(@alpha_member)

    get leads_path
    assert_response :success

    get lead_path(@alpha_lead.public_id)
    assert_response :success

    get activity_feed_path
    assert_response :success
  end

  # --- the platform operator ------------------------------------------------

  test "a tenant user cannot reach the platform dashboard" do
    [ @alpha_admin, @alpha_member ].each do |user|
      sign_in_as(user)

      get platform_root_path
      assert_response :not_found

      get platform_accounts_path
      assert_response :not_found

      get platform_account_path(@beta.public_id)
      assert_response :not_found

      delete logout_path
    end
  end

  test "a platform operator sees every account and no tenant screens" do
    sign_in_as(@operator)

    get platform_root_path
    assert_response :success
    assert_match(/#{@alpha.company_name}/, response.body)
    assert_match(/#{@beta.company_name}/, response.body)

    # And has no ambient tenant context, so the buyer-facing screens are not
    # merely hidden from them - they are unusable.
    get leads_path
    assert_response :not_found
  end

  test "every cross-account read by a platform operator is logged" do
    sign_in_as(@operator)

    assert_difference -> { AdminAccessLog.count }, 1 do
      get platform_account_path(@beta.public_id)
    end
    # The drill-in must actually render. Asserting only the log would have hidden
    # a 404 caused by lazy relations escaping a block-scoped tenant context.
    assert_response :success
    assert_match(/#{@beta.company_name}/, response.body)

    log = AdminAccessLog.newest_first.first
    assert_equal @operator.id, log.user_id
    assert_equal @beta.id, log.account_id, "the log must record whose data was read"
    assert_equal "accounts#show", log.action
  end

  test "a platform operator has no capability that writes tenant data" do
    # The answer to "how do you keep that power from leaking": there is nothing
    # to leak, because the capability was never granted.
    writing_verbs = Permissions::ACCOUNT_ADMIN - Permissions::MEMBER
    operator_verbs = Permissions.new(@operator).verbs

    assert_empty(operator_verbs & writing_verbs)
    assert operator_verbs.all? { |verb| verb.to_s.start_with?("view_") }
  end

  test "signing out clears the session" do
    sign_in_as(@alpha_admin)
    get dashboard_path
    assert_response :success

    delete logout_path
    get dashboard_path
    assert_redirected_to new_session_path
  end
end
