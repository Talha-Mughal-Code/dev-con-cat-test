module Verification
  # Runs on a schedule (see config/recurring.yml) so an abandoned run resolves
  # itself rather than waiting for someone to notice.
  class SweepStaleRunsJob < ApplicationJob
    queue_as :maintenance

    def perform(stale_after: nil)
      swept = StaleRunSweeper.call(
        **{ stale_after: stale_after }.compact_blank.symbolize_keys
      )
      return if swept.empty?

      Rails.logger.warn(
        "swept #{swept.size} stale verification #{'run'.pluralize(swept.size)}: " \
        "#{swept.map { |run| "#{run.lead.public_id}=#{run.verdict_label}" }.join(', ')}"
      )
    end
  end
end
