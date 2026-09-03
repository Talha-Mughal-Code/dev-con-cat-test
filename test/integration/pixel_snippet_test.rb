require "test_helper"

# Guards on the embed snippet itself.
#
# These are grep-level assertions rather than a JavaScript test suite, which is
# a deliberate trade: there is no JS runner in this project, and the failure
# these protect against was not subtle logic but a load-order mistake that made
# the live panel render NOTHING while every network request succeeded. A cheap
# structural check catches exactly that, and catches it in CI rather than in a
# browser someone happens to open.
class PixelSnippetTest < ActionDispatch::IntegrationTest
  PIXEL = Rails.root.join("public/super-pixel.js")

  # These assertions are about CODE, so comments are stripped first. Without
  # this, a comment explaining "the simulation is gone" trips the check looking
  # for a simulation, and a comment naming the anti-pattern trips the check
  # looking for the anti-pattern - which is precisely what happened.
  def code_only(path)
    source = path.read
    source = source.gsub(%r{/\*.*?\*/}m, "")   # /* block */
    source = source.gsub(%r{<!--.*?-->}m, "")   # <!-- html -->
    source.lines.reject { |line| line.strip.start_with?("//") }.join
  end
  HOST_PAGES = [
    Rails.root.join("app/views/demo/show.html.erb"),
    Rails.root.join("examples/landing-page.html")
  ].freeze

  test "the pixel is served, with a cache policy a fix can propagate through" do
    get "/super-pixel.js"

    assert_response :success
    assert_match %r{javascript}, response.media_type
    # The pixel is a third-party script on buyers' pages, so its cache lifetime
    # is also how long a correction takes to reach them.
    assert_match(/no-store|max-age=(\d{1,3})\b/, response.headers["cache-control"].to_s,
                 "the pixel must not be cached for long: #{response.headers['cache-control'].inspect}")
  end

  test "the simulation is gone, with no fallback that could invent a verdict" do
    source = code_only(PIXEL)

    # A pixel that fabricates reassuring results when the backend is unreachable
    # is worse than one that reports being offline, so there must be no such
    # path at all.
    assert_no_match(/simulateVerification|SIMULATION/i, source)
    assert_match(/EventSource/, source, "the real transport must be present")
  end

  test "the pixel exposes a ready queue, because the tag loads async" do
    source = code_only(PIXEL)

    assert_match(/SuperPixelQueue/, source)
    # A late subscriber must still receive events emitted before it subscribed,
    # or whichever side loses the race silently renders nothing.
    assert_match(/history/, source)
  end

  HOST_PAGES.each do |page|
    test "#{page.basename} subscribes through the queue, not a load-order guess" do
      source = code_only(page)

      assert_match(/SuperPixelQueue/, source,
                   "#{page.basename} must subscribe through the ready queue")

      # THE BUG THIS EXISTS FOR. `if (window.SuperPixel)` is only true when the
      # inline script happens to win the race against an async, cross-origin
      # script fetch. When it loses - which it usually does when the pixel is
      # served from another origin - the page registers no listener at all and
      # the activity panel stays empty forever, while every request to the
      # server succeeds. That is precisely the symptom that is hardest to debug
      # and most embarrassing to demo.
      assert_no_match(/if\s*\(\s*!?\s*window\.SuperPixel\s*\)/, source,
                      "#{page.basename} must not gate on window.SuperPixel existing")
    end

    test "#{page.basename} renders layer detail as text, never as markup" do
      source = code_only(page)

      # Layer summaries embed vendor-supplied strings. innerHTML on those would
      # be a stored-XSS vector on a buyer's own landing page.
      assert_match(/textContent/, source,
                   "#{page.basename} must use textContent for vendor-supplied detail")
    end
  end

  test "the demo form is pre-filled with someone who is not already a duplicate" do
    # The pre-filled values used to be seeded lead L-1001, who is already in the
    # CRM - so 'just press submit' returned REJECT (duplicate) while the page
    # promised an ACCEPT.
    source = Rails.root.join("app/views/demo/show.html.erb").read
    prefilled = source.scan(/name="(?:email|phone)"[^>]*value="([^"]+)"/).flatten

    seeded_emails = MockData.leads.map { |lead| lead["email"] }
    seeded_phones = MockData.leads.map { |lead| Lead.normalize_phone(lead["phone"]) }

    prefilled.each do |value|
      assert_not_includes seeded_emails, value,
                          "#{value} belongs to a seeded lead, so the demo would reject it as a duplicate"
      assert_not_includes seeded_phones, Lead.normalize_phone(value),
                          "#{value} belongs to a seeded lead, so the demo would reject it as a duplicate"
    end
  end
end
