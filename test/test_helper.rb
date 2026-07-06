ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Minitest 6 dropped `minitest/mock`. Tiny replacement for the `obj.stub(name, val) { }`
# form we use to fake Stripe class methods in tests. Restores the original after the block.
class Object
  def stub(name, replacement)
    meta = singleton_class
    had_own = meta.instance_methods(false).include?(name.to_sym)
    original = method(name) if had_own
    meta.define_method(name) do |*args, **kwargs, &blk|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &blk) : replacement
    end
    yield
  ensure
    meta.remove_method(name)
    meta.define_method(name, original) if had_own
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
  end
end
