# frozen_string_literal: true

redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379").strip
redis_network_timeout = ENV.fetch("REDIS_NETWORK_TIMEOUT") { "15" }.strip.to_i

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url, network_timeout: redis_network_timeout }
  config.average_scheduled_poll_interval = 5
  config.logger.level = Logger::INFO
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url, network_timeout: redis_network_timeout }
end


