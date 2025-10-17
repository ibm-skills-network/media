require "sidekiq/web"

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
  # Sidekiq Web UI with Basic Auth
  Sidekiq::Web.use Rack::Auth::Basic do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(username, Settings.sidekiq_credentials.username) &&
      ActiveSupport::SecurityUtils.secure_compare(password, Settings.sidekiq_credentials.password)
  end

  mount Sidekiq::Web => "/sidekiq"

  # API v1 routes
  namespace :api do
    namespace :v1 do
      namespace :async do
        namespace :videos do
          resources :qualities, only: [ :create, :show ]
        end
      end
    end
  end
end
