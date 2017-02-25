require 'test_helper'

class RackTest < ActiveSupport::TestCase

  setup do
    @pass_app = Object.new
    @pass_app.stubs(:call).returns([nil, { 'X-Cascade' => 'pass' }, nil])

    @normal_app = Object.new
    @normal_app.stubs(:call).returns([nil, { }, nil])
  end

  teardown do
    ExceptionNotifier.grouping_error = false
    ExceptionNotifier.send_grouped_error_trigger = nil
  end

  test "should ignore \"X-Cascade\" header by default" do
    ExceptionNotifier.expects(:notify_exception).never
    ExceptionNotification::Rack.new(@pass_app).call({})
  end

  test "should notify on \"X-Cascade\" = \"pass\" if ignore_cascade_pass option is false" do
    ExceptionNotifier.expects(:notify_exception).once
    ExceptionNotification::Rack.new(@pass_app, :ignore_cascade_pass => false).call({})
  end

  test "should assign grouping_error if grouping_error is specified" do
    assert_equal false, ExceptionNotifier.grouping_error
    ExceptionNotification::Rack.new(@normal_app, grouping_error: true).call({})
    assert_equal true, ExceptionNotifier.grouping_error
  end

  test "should assign send_grouped_error_trigger if send_grouped_error_trigger is specified" do
    assert_nil ExceptionNotifier.send_grouped_error_trigger
    ExceptionNotification::Rack.new(@normal_app, send_grouped_error_trigger: lambda {|i| true}).call({})
    assert_respond_to ExceptionNotifier.send_grouped_error_trigger, :call
  end
end
