require "test_helper"

class AcademicEmailTest < ActiveSupport::TestCase
  test "accepts the shapes schools actually use" do
    %w[a@mit.edu a@ox.ac.uk a@u-tokyo.ac.jp a@unimelb.edu.au A@Cs.Ox.Ac.Uk].each do |email|
      assert AcademicEmail.match?(email), email
    end
  end

  # .ac on its own is Ascension Island's TLD, open to anyone for a few dollars, so a bare .ac
  # domain bought the shared student code. Schools only use ac as the label before a country code.
  test "refuses a bare .ac domain" do
    refute AcademicEmail.match?("a@anything.ac")
    refute AcademicEmail.match?("a@school.ac")
  end

  test "refuses lookalikes and malformed addresses" do
    %w[a@edu.com a@ac.net a@mit.edu.evil.com a@gmail.com mit.edu @mit.edu a@ a@b@mit.edu a@mit..edu].each do |email|
      refute AcademicEmail.match?(email), email
    end
  end
end
