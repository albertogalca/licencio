Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "health" => "rails/health#show"

  namespace :api do
    get    "products/:slug/variants" => "products#variants"
    post   "checkout"            => "checkouts#create"
    post   "licenses/activate"   => "activations#create"
    delete "licenses/deactivate" => "activations#destroy"
    post   "licenses/recover"    => "recoveries#create"

    namespace :admin do
      post "migrations/import" => "migrations#import"
    end
  end

  namespace :admin do
    resource  :session, only: [ :new, :create, :destroy ]
    resources :products, only: [ :index, :new, :create, :edit, :update ]
    resources :licenses, only: [ :index, :new, :create, :edit, :update ]
    resources :customers, only: [ :index, :show ]
    resources :activations, only: :index
    root to: "products#index"
  end

  namespace :portal do
    get    "session", to: "sessions#create"      # magic-link consume (GET link)
    delete "session", to: "sessions#destroy"     # logout
    resources :activations, only: :destroy       # deactivate a device
    resources :recoveries, only: [ :new, :create ] # public recovery form
    root to: "dashboard#show"
  end

  # Each Stripe account POSTs to its own product's endpoint; verified with that
  # product's stripe_webhook_secret.
  post "webhooks/stripe/:product_id" => "webhooks/stripe#create", as: :webhooks_stripe

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
