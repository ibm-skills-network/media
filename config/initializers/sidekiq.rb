# frozen_string_literal: true

redis_network_timeout = ENV.fetch("REDIS_NETWORK_TIMEOUT") { "15" }.strip.to_i

redis_config = if Settings.redis && Settings.redis.sentinel
  {
    url: Settings.redis.url || "redis://localhost:6379",
    role: "master",
    sentinels: [
      {
        host: Settings.redis.sentinel.host,
        port: Settings.redis.sentinel.port,
        password: Settings.redis.sentinel.password
      }
    ],
    password: Settings.redis.sentinel.password,
    network_timeout: redis_network_timeout
  }
else
  {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6381").strip,
    network_timeout: redis_network_timeout
  }
end

Sidekiq.configure_server do |config|
  config.redis = redis_config
  config.average_scheduled_poll_interval = 5
  config.logger.level = Logger::INFO
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end


# Sidekiq::Cron::Job.load_from_hash(Settingsp.cron_jobs.to_hash) if Sidekiq.server?

# Sidekiq::Cron::Job.all.map(&:disable!) if Rails.env.development?
