Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]                # set in Coolify; kept out of the public repo so clones don't report here
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = false               # no licensee IP/email/params sent to Sentry
  config.rails.structured_logging.enabled = false # sentry 7 ships Rails logs by default; they carry emails and keys
  config.enabled_environments = %w[production]   # dev/test load the gem but send nothing
end
