class ApplicationJob < ActiveJob::Base
  # Transient upstream failures (Loops 5xx, network blips) retry with backoff
  # instead of dropping the only email the app sends.
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # A record deleted before the job runs is nothing to retry.
  discard_on ActiveJob::DeserializationError
end
