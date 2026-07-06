# Host for URLs generated outside a request (e.g. magic links built in MagicLinkJob).
Rails.application.routes.default_url_options[:host] = ENV.fetch("APP_HOST", "localhost:3000")
