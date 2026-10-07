# Request context the models need but should not take as arguments. Reset after every request.
class Current < ActiveSupport::CurrentAttributes
  attribute :ip_address
end
