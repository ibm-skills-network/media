class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
  sidekiq_options retry: 5

  sidekiq_retries_exhausted do |msg, exception|
    Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
  end
end
