source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data"

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Background job processing
gem "sidekiq"

# HTTP client library
gem "faraday"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  # Call 'byebug' anywhere in the code to stop execution and get a debugger console
  gem "byebug", platforms: %i[mri mingw x64_mingw]

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false
  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # RSpec for testing
  gem "rspec-rails", "~> 6.0"
  # FactoryBot for creating model instances for tests
  gem "factory_bot_rails", "~> 6.2"
  # Faker for generating fake data for tests
  gem "faker", "~> 2.21"
  # Codecov for code coverage reporting
  gem "simplecov", require: false
  # Capybara for acceptance tests
  gem "capybara", "~> 3"
  # Launchy for opening URLs in a browser
  gem "launchy", "~> 3"
  # Cypress for E2E tests
  gem "cypress-rails", "~> 0.5"
  # assert_template for controller tests
  gem "rails-controller-testing", "~> 1.0.5"
end

group :development do
  # Display performance information such as SQL time and flame graphs for each request in your browser.
  # Can be configured to work on production as well see: https://github.com/MiniProfiler/rack-mini-profiler/blob/master/README.md
  gem "rack-mini-profiler", "~> 3.0"

  # A good ERB templating engine
  gem "herb"

  # Spring speeds up development by keeping your application running in the background. Read more: https://github.com/rails/spring
  gem "spring"

  # Access an interactive console on exception pages or by calling 'console' anywhere in the code.
  gem "rufo", "~> 0.18.0"
  gem "web-console", ">= 4.1.0"

  # Stub request in development
  gem "webmock", "~> 3.13"

  # ViewComponent development UI
  gem "lookbook", "~> 2"

  # Help identify inefficient n+1 queries
  gem "bullet"

  # format those ERB templates
  gem "erb-formatter", "~> 0.7.3"

  # Process manager for Procfile-based applications
  gem "foreman"
end

group :development, :rubocop do
  gem "rubocop-github", "~> 0.26.0" # Rubocop github flavour
  gem "rubocop-performance"
  gem "rubocop-rails"
end

group :test do
  # Easy installation and use of web drivers to run system tests with browsers
  gem "webdrivers"
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "selenium-webdriver"

  # WithModel for temporarily creating ActiveRecord models during tests
  gem "with_model", "~> 2.1"
end

group :production do
  # integration with our APM Instana
  gem "instana", "~> 1"
end
