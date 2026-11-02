require "test_helper"
require "rake"

class CodesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { it.name == "codes:generate" }
    Rake::Task["codes:generate"].reenable
  end

  test "generate with no count makes the default pool, written to OUT and nowhere else" do
    Dir.mktmpdir do |dir|
      out = File.join(dir, "codes.csv")
      stdout, = capture_io do
        with_env("OUT" => out) { Rake::Task["codes:generate"].invoke("picmal") }
      end

      codes = File.read(out).lines(chomp: true)
      assert_equal 10_000, codes.size
      assert_equal 10_000, products(:picmal).redemption_codes.count
      assert_empty stdout
      assert_equal "600", format("%o", File.stat(out).mode & 0o777)
    end
  end

  private
    def with_env(vars)
      old = vars.keys.index_with { ENV[it] }
      vars.each { ENV[_1] = _2 }
      yield
    ensure
      old.each { ENV[_1] = _2 }
    end
end
