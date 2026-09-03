require "net/http"
require "json"
require "uri"

# Drives the pixel's public API over real HTTP, the way a browser does.
#
# Exists because the interesting behaviour of this system is end-to-end - a
# capture session, a lead, background jobs, and an event stream - and curl
# one-liners for that are long enough to get wrong. Useful for a reviewer who
# wants to exercise a scenario without opening a browser, and for reproducing
# concurrency bugs, which a browser cannot do on demand.
namespace :demo do
  BASE = ENV.fetch("BASE", "http://localhost:3000")
  # Defaults to a cross-origin call, since that is the pixel's real situation:
  # running on a buyer's domain, not ours.
  ORIGIN = ENV.fetch("ORIGIN", "http://localhost:3001")
  PIXEL = ENV.fetch("PIXEL", "px_9f2a01")

  def post_json(path, body)
    uri = URI.join(BASE, path)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Origin"] = ORIGIN
    request["User-Agent"] = ENV.fetch("UA", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
    request.body = JSON.generate(body)

    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    parsed = JSON.parse(response.body) rescue { "raw" => response.body[0, 200] }
    [ response.code.to_i, parsed ]
  end

  def stream(activity_url, token, seconds: 20)
    uri = URI.join(BASE, "#{activity_url}&token=#{token}")
    layers = []
    verdict = nil

    Net::HTTP.start(uri.hostname, uri.port, read_timeout: seconds) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "text/event-stream"
      request["Origin"] = ORIGIN

      http.request(request) do |response|
        response.read_body do |chunk|
          chunk.each_line do |line|
            next unless line.start_with?("data:")

            event = JSON.parse(line[5..]) rescue next
            case event["type"]
            when "layer_result" then layers << event
            when "final_verdict" then verdict = event
            end
          end
          break if verdict
        end
      end
    end

    [ layers, verdict ]
  rescue Net::ReadTimeout, EOFError
    [ layers, verdict ]
  end

  desc "Submit one lead through the pixel API and print the live results"
  task :lead do
    dwell = ENV.fetch("DWELL", "6").to_f
    fields = {
      first_name: ENV.fetch("FIRST", "Ada"),
      last_name: ENV.fetch("LAST", "Lovelace"),
      email: ENV.fetch("EMAIL", "ada.lovelace@gmail.com"),
      phone: ENV.fetch("PHONE", "+14152228890")
    }
    fields[:consent] = ENV["CONSENT"] != "false" if ENV.key?("CONSENT") || true

    session_id = "rake-#{SecureRandom.hex(4)}"
    code, visit = post_json("/api/pixel/visit",
                            pixel_id: PIXEL, session_id: session_id,
                            page_url: "#{ORIGIN}/landing-page.html")
    abort "  /visit failed (#{code}): #{visit}" unless code == 202

    puts "  session opened, #{visit['layers'].size} layers subscribed on this account"
    puts "  waiting #{dwell}s to simulate filling the form..."
    sleep dwell

    code, lead = post_json("/api/pixel/leads",
                           pixel_id: PIXEL, session_id: session_id, token: visit["token"],
                           page_url: "#{ORIGIN}/landing-page.html", fields: fields)
    abort "  /leads failed (#{code}): #{lead}" unless code == 201

    puts "  lead #{lead['lead_id']} accepted; streaming verification\n\n"
    layers, verdict = stream(lead["activity_url"], lead["stream_token"])

    layers.each_with_index do |layer, index|
      puts format("  %2d. %-22s %-12s %s", index + 1, layer["name"] || layer["layer"],
                  layer["verdict"], layer["detail"].to_s[0, 60])
    end

    if verdict
      puts
      puts "  #{verdict['verdict']}  -  #{verdict['code']}  -  " \
           "confidence #{(verdict['score'].to_f * 100).round}%  -  " \
           "#{verdict['credits_charged']} credits"
      verdict["reasons"].to_a.each { |reason| puts "    - #{reason}" }
    else
      puts "\n  no final verdict within the timeout - is the job worker running?"
    end
  end

  desc "Fire N leads at once, to exercise concurrency (N=6 by default)"
  task :concurrent do
    count = ENV.fetch("N", "6").to_i
    puts "  firing #{count} leads simultaneously\n\n"

    results = count.times.map do |index|
      Thread.new do
        session_id = "burst-#{SecureRandom.hex(4)}"
        started = Time.current
        code, visit = post_json("/api/pixel/visit",
                                pixel_id: PIXEL, session_id: session_id,
                                page_url: "#{ORIGIN}/landing-page.html")
        visit_ms = ((Time.current - started) * 1000).round
        next { visit: code, visit_ms: visit_ms } unless code == 202

        sleep 6
        started = Time.current
        code, lead = post_json("/api/pixel/leads",
                               pixel_id: PIXEL, session_id: session_id, token: visit["token"],
                               fields: { first_name: "Burst", last_name: "Test#{index}",
                                         email: "burst.test#{index}@gmail.com",
                                         phone: "+1206555#{format('%04d', 7000 + index)}",
                                         consent: true })
        { visit: 202, visit_ms: visit_ms, leads: code,
          leads_ms: ((Time.current - started) * 1000).round, lead_id: lead["lead_id"] }
      end
    rescue StandardError => e
      Thread.new { { visit: e.class.name.split("::").last } }
    end.map(&:value)

    results.each_with_index do |result, index|
      puts format("  %2d. visit %-14s %6sms   leads %-4s %6sms   %s", index + 1,
                  result[:visit], result[:visit_ms], result[:leads] || "-",
                  result[:leads_ms] || "-", result[:lead_id] || "")
    end

    ok = results.count { |r| r[:visit] == 202 && r[:leads] == 201 }
    timings = results.filter_map { |r| r[:leads_ms] }
    puts "\n  #{ok}/#{results.size} succeeded"
    if timings.any?
      puts "  /leads latency: median #{timings.sort[timings.size / 2]}ms, " \
           "worst #{timings.max}ms"
    end
    abort "  #{results.size - ok} request(s) failed" if ok < results.size
  end

  desc "Fire two visit beacons for the SAME session at once (idempotence check)"
  task :duplicate_beacon do
    session_id = "same-session-#{SecureRandom.hex(4)}"
    puts "  two concurrent /visit beacons, identical session_id\n\n"

    codes = 2.times.map do
      Thread.new do
        post_json("/api/pixel/visit", pixel_id: PIXEL, session_id: session_id,
                                      page_url: "#{ORIGIN}/landing-page.html").first
      end
    end.map(&:value)

    puts "  responses: #{codes.join(', ')}"
    if codes.all? { |c| c == 202 }
      puts "  both accepted - the beacon is idempotent"
    else
      abort "  a duplicate beacon returned #{codes.reject { |c| c == 202 }.join(', ')}"
    end
  end
end
