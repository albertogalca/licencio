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
    # Single-process: pg 1.6.3's async connect segfaults after fork() on Ruby 4.0.1 + macOS.
    # ponytail: revert to :number_of_processors once a fixed pg/Ruby combo lands.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
  end
end
