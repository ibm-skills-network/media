require "sidekiq/web"

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
  # Sidekiq Web UI
  mount Sidekiq::Web => "/sidekiq"

  get :test, to: "tests#test_nvenc_codecs"
  get :testvideo, to: "tests#test_1080p_conversion"
  get :testnvenc, to: "tests#testvideonv"
  # Video API routes
  resources :videos, only: [ :create, :index, :show ] do
    get :poll, on: :member
  end
end
