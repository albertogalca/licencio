require "test_helper"

class StudentDiscountJobTest < ActiveJob::TestCase
  test "the same student asking for two products on one day gets both codes" do
    picmal = products(:picmal)
    cozy   = products(:cozy)
    cozy.update!(student_transactional_id: "tmpl_cozy_student", student_discount_code: "COZYEDU")

    codes = []
    Loops.stub(:send_transactional, ->(**kwargs) { codes << kwargs[:data][:discount_code] }) do
      StudentDiscountJob.perform_now(cozy, "drmoali@uw.edu")
      StudentDiscountJob.perform_now(picmal, "drmoali@uw.edu")
    end

    assert_equal %w[COZYEDU STUDENT], codes,
      "the daily dedup key must carry the product, or the second product's code is swallowed"
  end

  test "asking twice for the same product on one day sends once" do
    picmal = products(:picmal)

    sends = 0
    Loops.stub(:send_transactional, ->(**) { sends += 1 }) do
      2.times { StudentDiscountJob.perform_now(picmal, "drmoali@uw.edu") }
    end

    assert_equal 1, sends
  end
end
