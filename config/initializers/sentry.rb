Sentry.init do |config|
  config.dsn = "https://c98b9cf27d3c880aeb7708ecf2cf2fe8@o4510719096717312.ingest.de.sentry.io/4511717090394192"
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = false               # no licensee IP/email/params sent to Sentry
  config.enabled_environments = %w[production]   # dev/test load the gem but send nothing
end
