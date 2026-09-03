require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SuperPixel
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "UTC"

    # Layer verification runs as background jobs; Solid Queue keeps them durable
    # and inspectable without introducing Redis. See SOLUTION.md ("Jobs").
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }

    # Domain code lives in plain-old-Ruby namespaces rather than being crammed
    # into models or controllers:
    #   app/engine    - the consensus engine (pure, no DB writes)
    #   app/providers - the vendor gateway (mock fixtures / deterministic sim)
    #   app/policies  - authorization
    #   app/services  - orchestration that spans models
    config.generators.system_tests = nil

    # Simulated vendor latency. Real vendor calls take a few hundred
    # milliseconds, and the live activity panel is only convincing if layers
    # land one at a time - so the mock gateway sleeps within this range. Zero in
    # the test environment, where it would only slow the suite down.
    config.x.provider_latency_ms = (120..600)
  end
end
