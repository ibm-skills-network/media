source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.6", platform: :ruby
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# JWT authentication
gem "jwt"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false
# Background job processing
gem "sidekiq"
gem "sidekiq-cron"

gem "redis"

gem "aws-sdk-s3"
# Application configuration
gem "config"

# HTTP client library
gem "faraday"
# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

gem "data_migrate"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ]

    # RSpec for testing
    gem "rspec-rails", "~> 6.0"
    # FactoryBot for creating model instances for tests
    gem "factory_bot_rails", "~> 6.2"
    # Faker for generating fake data for tests
    gem "faker", "~> 2.21"
end

group :development, :rubocop do
  gem "rubocop-rails-omakase"
  gem "rubocop-github", "~> 0.17.0" # Rubocop github flavour
  gem "rubocop-performance"
  gem "rubocop-rails"
end

gem "jbuilder", "~> 2.14"
