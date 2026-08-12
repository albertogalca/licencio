require "test_helper"

class Api::StudentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { @product = products(:picmal) }

  def ask(email:, slug: @product.slug)
    post "/api/students/discount", params: { product_slug: slug, email: }, as: :json
  end

  test "a school address gets the code mailed to it" do
    assert_enqueued_with(job: StudentDiscountJob) { ask(email: "A.Name@MIT.edu") }
    assert_response :ok
    assert_equal({ "sent" => true }, response.parsed_body)
  end

  test "the response never carries the code" do
    ask(email: "a@ox.ac.uk")
    assert_not_includes response.body, @product.student_discount_code
  end

  test "a non-school address is refused and mails nothing" do
    assert_no_enqueued_jobs do
      ask(email: "a@gmail.com")
      assert_response :unprocessable_entity
      assert_equal "not_academic_email", response.parsed_body["code"]
    end
  end

  test "edu.com and friends don't sneak through" do
    assert_no_enqueued_jobs do
      [ "a@edu.com", "a@myedu.io", "a@mit.edu.evil.com", "@mit.edu", "a@" ].each do |email|
        ask(email:)
        assert_response :unprocessable_entity, email
      end
    end
  end

  test "a product without student pricing configured says so" do
    assert_no_enqueued_jobs do
      ask(email: "a@mit.edu", slug: products(:cozy).slug)
      assert_response :service_unavailable
    end
  end

  test "no api key is needed and the preflight passes" do
    process :options, "/api/students/discount"
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "the same address only gets one code a day" do
    perform_enqueued_jobs do
      Loops.stub :send_transactional, ->(**) { :sent } do
        2.times { ask(email: "a@mit.edu") }
      end
    end
    assert_equal 1, Notification.where(kind: "student_discount").count
  end
end
