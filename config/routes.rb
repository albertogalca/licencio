Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "health" => "rails/health#show"

  namespace :api do
    get    "products/:product_slug/variants" => "products#variants"
    get    "products/:product_slug/stats"    => "products#stats"
    get    "checkout"            => "checkouts#new"    # buy button → 302 to Stripe Checkout
    post   "checkout"            => "checkouts#create" # same session as JSON { url }
    post   "licenses/activate"   => "activations#create"
    delete "licenses/deactivate" => "activations#destroy"
    post   "licenses/recover"    => "recoveries#create"
    # Public (no API key): lets an App Store binary check a desktop key without shipping
    # the credential that mints licenses. Read-only — no activation, no seat.
    post   "licenses/validate"   => "validations#create"
    match  "licenses/validate"   => "validations#preflight", via: :options
    # Public: a storefront posts a school email here and the discount code is mailed to it.
    post   "students/discount"   => "students#create"
    match  "students/discount"   => "students#preflight", via: :options

    namespace :admin do
      post "migrations/import" => "migrations#import"
    end
  end

  # Unlock by email: no accounts, no keys, no device limit. Public and CORS-wildcard,
  # because Cozy for iPhone posts from capacitor://localhost.
  namespace :v1 do
    post  "unlock/request" => "unlocks#request_code"
    match "unlock/request" => "unlocks#preflight", via: :options
    post  "unlock/verify"  => "unlocks#verify"
    match "unlock/verify"  => "unlocks#preflight", via: :options
    # Shared-secret (X-Admin-Token), for answering "what did this address buy?" by hand.
    post  "support/lookup" => "support#lookup"
  end

  namespace :admin do
    resource  :session, only: [ :new, :create, :destroy ]
    resources :products, only: [ :index, :new, :create, :edit, :update ]
    resources :licenses, only: [ :index, :new, :create, :edit, :update ] do
      resources :emails, only: :create # resend a lifecycle email (kind param)
    end
    resources :customers, only: [ :index, :show ]
    resources :activations, only: [ :index, :destroy ]
    resources :affiliates, only: [ :index, :show, :edit, :update ] do
      resource  :approval, only: :create # approving = creating an approval (mints the magic link)
      resources :payouts,  only: :create # "Mark paid"
    end
    root to: "dashboard#show"
  end

  namespace :affiliate do
    resource  :signup,     only: [ :new, :create ]  # public self-signup
    resources :recoveries, only: [ :new, :create ]  # "email me my dashboard link"
    get    "session", to: "sessions#create"         # magic-link consume (GET)
    delete "session", to: "sessions#destroy"        # logout
    root to: "dashboard#show"
  end

  namespace :portal do
    get    "session", to: "sessions#create"      # magic-link consume (GET link)
    delete "session", to: "sessions#destroy"     # logout
    resources :activations, only: :destroy       # deactivate a device
    resources :renewals, only: [ :new, :create ] # renew a license via Stripe checkout (public, keyed on the license key)
    resources :recoveries, only: [ :new, :create ] # public recovery form
    root to: "dashboard#show"
  end

  # Each Stripe account POSTs to its own product's endpoint; verified with that
  # product's stripe_webhook_secret.
  post "webhooks/stripe/:product_id" => "webhooks/stripe#create", as: :webhooks_stripe

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # No public landing page — send the bare domain to the admin.
  root to: redirect("/admin")
end
