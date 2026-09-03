module ApplicationHelper
  def nav_link(label, path)
    on = current_page?(path) || (path != "/" && request.path.start_with?(path))
    link_to label, path, class: on ? "on" : nil
  end

  # Maps a layer's display status onto a badge class. The vocabulary is wider
  # than pass/warn/fail on purpose: "not enabled" and "unavailable" must not look
  # like either a pass or a failure.
  def status_badge(status)
    tag.span(status.to_s.humanize.downcase, class: "badge b-#{status}")
  end

  def verdict_badge(verdict)
    return tag.span("no verdict", class: "badge b-skip") if verdict.blank?

    tag.span(verdict.to_s.upcase, class: "badge b-#{verdict}")
  end

  def run_status_badge(run)
    return tag.span("not verified", class: "badge b-skip") if run.nil?
    return verdict_badge(run.verdict) if run.completed?

    label = case run.status
    when "halted_insufficient_credits" then "halted - no credits"
    when "errored" then "errored"
    else "verifying"
    end
    tag.span(label, class: "badge b-#{run.halted? || run.errored? ? 'unavailable' : 'pending'}")
  end

  def credit_badge_class(account)
    case account.credit_health
    when :exhausted, :critical then "b-fail"
    when :low then "b-warn"
    else "b-pass"
    end
  end

  def health_badge(account)
    tag.span(account.credit_health.to_s, class: "badge #{credit_badge_class(account)}")
  end

  def percent(value, precision: 0)
    return "-" if value.nil?

    "#{(value.to_f * 100).round(precision)}%"
  end

  def days_label(days)
    return "-" if days.nil?
    return "never at this rate" if days.infinite?
    return "under a day" if days < 1

    "#{days.round(1)} days"
  end

  def risk_meter(risk)
    tag.div(class: "meter risk") { tag.span(style: "width: #{(risk.to_f * 100).clamp(0, 100)}%") }
  end

  def time_short(time)
    return "-" if time.blank?

    tag.span(time.strftime("%d %b %H:%M"), title: time.iso8601, class: "nowrap")
  end

  def reason_items(reasons)
    Array(reasons).map do |reason|
      reason = reason.with_indifferent_access
      tag.li(class: reason[:severity]) do
        safe_join([
          tag.span(reason[:message]),
          reason[:weight] ? tag.span("+#{reason[:weight]}", class: "muted small nowrap") : nil
        ].compact)
      end
    end.then { |items| tag.ul(safe_join(items), class: "reasons") }
  end
end
