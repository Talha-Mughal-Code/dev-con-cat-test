require "test_helper"

# The pixel's public API.
#
# docs/pixel-spec.md asks three security questions; these tests are the answers,
# asserted rather than asserted-in-prose:
#
#   * How do you stop someone POSTing leads to another account's pixel?
#   * What stops the endpoint being abused or replayed?
#   * What lives client-side (and is therefore untrusted) vs server-side?
class PixelApiTest < ActionDispatch::IntegrationTest
  ALLOWED = "https://solar.example.com".freeze
  HOSTILE = "https://attacker.example.com".freeze

  setup do
    @account = build_account(public_id: "acct_pixel")
    @other = build_account(public_id: "acct_other")
    @pixel = build_pixel(account: @account, origins: [ ALLOWED ])
    @other_pixel = build_pixel(account: @other, origins: [ ALLOWED ])
  end

  def open_session_for(pixel = @pixel, origin: ALLOWED, session_id: "sess-under-test")
    post "/api/pixel/visit",
         params: { pixel_id: pixel.public_id, session_id: session_id,
                   page_url: "#{origin}/quote" }.to_json,
         headers: { "Content-Type" => "application/json", "Origin" => origin }
    JSON.parse(response.body)
  end

  def submit_lead(pixel: @pixel, token:, session_id: "sess-under-test", origin: ALLOWED, fields: {})
    post "/api/pixel/leads",
         params: { pixel_id: pixel.public_id, session_id: session_id, token: token,
                   fields: { first_name: "Test", last_name: "Person",
                             email: "test@example.com", phone: "+14155550000" }.merge(fields) }.to_json,
         headers: { "Content-Type" => "application/json", "Origin" => origin }
    response.parsed_body
  end

  # --- the origin allowlist -------------------------------------------------

  test "a visit from an allowed origin opens a session" do
    payload = open_session_for

    assert_response :accepted
    assert payload["session_id"].start_with?("sess_")
    assert payload["token"].present?
    # The pixel advertises the layers this account actually pays for, so the
    # panel shows the real stack rather than a hardcoded list.
    assert_equal @account.enabled_module_costs.size, payload["layers"].size
  end

  test "a visit from an origin the pixel does not allow is refused" do
    # The pixel id is public - it is in the page source - so it cannot be a
    # credential. This is the control that actually stops a third party posting
    # into someone else's account.
    open_session_for(origin: HOSTILE)

    assert_response :forbidden
    assert_match(/not allowed/, response.parsed_body["error"])
  end

  test "an empty allowlist accepts nothing rather than everything" do
    wide_open = build_pixel(account: @account, name: "No origins", origins: [])

    open_session_for(wide_open, origin: ALLOWED)
    assert_response :forbidden
  end

  test "an unknown or paused pixel is refused" do
    post "/api/pixel/visit",
         params: { pixel_id: "px_does_not_exist", session_id: "x" }.to_json,
         headers: { "Content-Type" => "application/json", "Origin" => ALLOWED }
    assert_response :not_found

    @pixel.update!(status: "paused")
    open_session_for
    assert_response :not_found
  end

  test "CORS headers are reflected only for origins a pixel authorises" do
    open_session_for(origin: ALLOWED)
    assert_equal ALLOWED, response.headers["Access-Control-Allow-Origin"]
    assert_equal "Origin", response.headers["Vary"]

    open_session_for(origin: HOSTILE)
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  # --- the capture token ----------------------------------------------------

  test "a lead cannot be submitted without a capture token" do
    # Otherwise the public pixel id alone would be enough to inject leads.
    submit_lead(token: nil)
    assert_response :unauthorized

    submit_lead(token: "capture.#{Time.current.to_i}.deadbeef")
    assert_response :unauthorized
  end

  test "a valid capture token accepts the lead and queues verification" do
    token = open_session_for.fetch("token")

    assert_enqueued_with(job: Verification::StartJob) do
      payload = submit_lead(token: token)
      assert_response :created
      assert payload["lead_id"].start_with?("L-")
      assert payload["activity_url"].present?
      assert payload["stream_token"].present?
    end
  end

  test "a capture token cannot be replayed into a different session" do
    token = open_session_for(session_id: "session-one").fetch("token")

    submit_lead(token: token, session_id: "session-two")
    assert_response :unauthorized
  end

  test "a capture token issued for one pixel is useless on another" do
    # Signed with the issuing pixel's own secret, so this is the mechanism that
    # makes "revoke this pixel" mean something.
    token = open_session_for(@pixel).fetch("token")

    submit_lead(pixel: @other_pixel, token: token)
    assert_response :unauthorized
  end

  test "rotating a pixel's secret invalidates tokens it already issued" do
    token = open_session_for.fetch("token")
    @pixel.regenerate_signing_secret

    submit_lead(token: token)
    assert_response :unauthorized
  end

  test "an expired capture token is refused" do
    token = open_session_for.fetch("token")

    travel (Capture::SessionToken::PURPOSES.fetch(:capture) + 1.minute) do
      submit_lead(token: token)
      assert_response :unauthorized
    end
  end

  test "a stream token cannot be used to submit a lead" do
    # Purpose separation. The stream credential travels in a URL because
    # EventSource cannot set headers, so it must not be interchangeable with the
    # one that writes.
    token = open_session_for.fetch("token")
    stream_token = submit_lead(token: token).fetch("stream_token")

    open_session_for(session_id: "second-session")
    submit_lead(token: stream_token, session_id: "second-session")
    assert_response :unauthorized
  end

  # --- nothing from the client is authoritative -----------------------------

  test "the lead is attributed to the pixel's account, whatever the request claims" do
    # There is no parameter that can point a lead at another account: the account
    # is derived server-side from the pixel record.
    token = open_session_for.fetch("token")

    post "/api/pixel/leads",
         params: { pixel_id: @pixel.public_id, session_id: "sess-under-test", token: token,
                   # All three are attempts to nominate a different owner.
                   account_id: @other.id, account: @other.public_id,
                   lead: { account_id: @other.id },
                   fields: { first_name: "Test", email: "t@example.com", phone: "+14155550000" } }.to_json,
         headers: { "Content-Type" => "application/json", "Origin" => ALLOWED }

    assert_response :created
    lead = TenantScope.across_accounts { Lead.find_by!(public_id: response.parsed_body["lead_id"]) }
    assert_equal @account.id, lead.account_id
    assert_equal 0, TenantScope.for_account(@other) { Lead.count }
  end

  test "dwell time is measured by the server, not reported by the client" do
    # It is a fraud signal, so a fraudster would simply send a flattering number.
    token = open_session_for.fetch("token")

    post "/api/pixel/leads",
         params: { pixel_id: @pixel.public_id, session_id: "sess-under-test", token: token,
                   form_dwell_ms: 90_000, # the client's claim
                   fields: { first_name: "Test", email: "t@example.com", phone: "+14155550000" } }.to_json,
         headers: { "Content-Type" => "application/json", "Origin" => ALLOWED }

    lead = TenantScope.across_accounts { Lead.find_by!(public_id: response.parsed_body["lead_id"]) }
    assert_operator lead.form_dwell_ms, :<, 5_000, "the client's 90 seconds must not be believed"
    assert_operator lead.form_dwell_ms, :>=, 0, "and the measurement can never go negative"
  end

  test "the submit IP comes from the connection and is compared to the visit IP" do
    open_session_for
    session = TenantScope.for_account(@account) { CaptureSession.sole }
    assert session.visit_ip.present?

    token = Capture::SessionToken.new(@pixel).issue(purpose: :capture,
                                                    subject: session.public_id, ip: "127.0.0.1")
    submit_lead(token: token)

    assert_equal session.visit_ip, session.reload.submit_ip
    assert_equal true, session.ip_consistent?
  end

  test "an absent consent field is recorded as not captured, not as declined" do
    # The tri-state distinction, end to end.
    token = open_session_for.fetch("token")
    payload = submit_lead(token: token)
    lead = TenantScope.across_accounts { Lead.find_by!(public_id: payload["lead_id"]) }
    assert_nil lead.consent_checkbox

    open_session_for(session_id: "unticked")
    token2 = response.parsed_body.fetch("token")
    payload2 = submit_lead(token: token2, session_id: "unticked", fields: { consent: false })
    lead2 = TenantScope.across_accounts { Lead.find_by!(public_id: payload2["lead_id"]) }
    assert_equal false, lead2.consent_checkbox
  end

  # --- the activity stream --------------------------------------------------

  test "the activity stream requires a valid stream token" do
    token = open_session_for.fetch("token")
    payload = submit_lead(token: token)

    get "#{payload['activity_url']}&token=nonsense", headers: { "Origin" => ALLOWED }
    assert_response :unauthorized

    get payload["activity_url"], headers: { "Origin" => ALLOWED }
    assert_response :unauthorized
  end

  test "a stream token for one lead cannot watch another" do
    token = open_session_for.fetch("token")
    first = submit_lead(token: token)

    open_session_for(session_id: "second")
    second = submit_lead(token: response.parsed_body.fetch("token"), session_id: "second")

    get "#{second['activity_url']}&token=#{first['stream_token']}", headers: { "Origin" => ALLOWED }
    assert_response :unauthorized
  end

  test "a lead in another account cannot be streamed even with a valid token" do
    other_lead = build_lead(account: @other, pixel: @other_pixel)
    token = open_session_for.fetch("token")
    submit_lead(token: token)

    stream_token = Capture::SessionToken.new(@pixel).issue(
      purpose: :stream, subject: other_lead.public_id, ip: "127.0.0.1"
    )

    get "/api/pixel/leads/#{other_lead.public_id}/activity",
        params: { pixel_id: @pixel.public_id, token: stream_token },
        headers: { "Origin" => ALLOWED }

    # Indistinguishable from a lead that does not exist, because the lookup never
    # left this pixel's account.
    assert_response :not_found
  end

  test "the polling fallback returns the same events as the stream" do
    token = open_session_for.fetch("token")
    payload = submit_lead(token: token)
    lead = TenantScope.across_accounts { Lead.find_by!(public_id: payload["lead_id"]) }
    perform_enqueued_jobs

    get "#{payload['activity_url']}&token=#{payload['stream_token']}&format=json",
        headers: { "Origin" => ALLOWED }

    assert_response :success
    events = response.parsed_body
    assert events.any?
    assert_equal TenantScope.for_account(@account) { ActivityEvent.where(lead: lead).count },
                 events.size
    # Monotonic ids are what make them usable as a resume cursor.
    assert_equal events.map { |e| e["id"] }.sort, events.map { |e| e["id"] }
  end

  test "a preflight is answered without a body" do
    process :options, "/api/pixel/leads", headers: { "Origin" => ALLOWED }
    assert_response :no_content
  end
end
