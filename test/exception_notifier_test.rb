require 'test_helper'

class ExceptionOne < StandardError;end
class ExceptionTwo < StandardError;end

class ExceptionNotifierTest < ActiveSupport::TestCase
  setup do
    @notifier_calls = 0
    @test_notifier = lambda { |exception, options| @notifier_calls += 1 }
  end

  teardown do
    ExceptionNotifier.class_eval("@@notifiers.delete_if { |k, _| k.to_s != \"email\"}")  # reset notifiers
    Rails.cache.clear
  end

  test "should have default ignored exceptions" do
    assert_equal ExceptionNotifier.ignored_exceptions,
      ['ActiveRecord::RecordNotFound', 'Mongoid::Errors::DocumentNotFound', 'AbstractController::ActionNotFound',
       'ActionController::RoutingError', 'ActionController::UnknownFormat', 'ActionController::UrlGenerationError']
  end

  test "should have email notifier registered" do
    assert_equal ExceptionNotifier.notifiers, [:email]
  end

  test "should have a valid email notifier" do
    @email_notifier = ExceptionNotifier.registered_exception_notifier(:email)
    refute_nil @email_notifier
    assert_equal @email_notifier.class, ExceptionNotifier::EmailNotifier
    assert_respond_to @email_notifier, :call
  end

  test "should allow register/unregister another notifier" do
    ExceptionNotifier.stubs(:skip_notification_for_grouping_error?).returns(false)

    called = false
    proc_notifier = lambda { |exception, options| called = true }
    ExceptionNotifier.register_exception_notifier(:proc, proc_notifier)

    assert_equal ExceptionNotifier.notifiers.sort, [:email, :proc]

    exception = StandardError.new

    ExceptionNotifier.notify_exception(exception)
    assert called

    ExceptionNotifier.unregister_exception_notifier(:proc)
    assert_equal ExceptionNotifier.notifiers, [:email]
  end

  test "should allow select notifiers to send error to" do
    ExceptionNotifier.stubs(:skip_notification_for_grouping_error?).returns(false)

    notifier1_calls = 0
    notifier1 = lambda { |exception, options| notifier1_calls += 1 }
    ExceptionNotifier.register_exception_notifier(:notifier1, notifier1)

    notifier2_calls = 0
    notifier2 = lambda { |exception, options| notifier2_calls += 1 }
    ExceptionNotifier.register_exception_notifier(:notifier2, notifier2)

    assert_equal ExceptionNotifier.notifiers.sort, [:email, :notifier1, :notifier2]

    exception = StandardError.new
    ExceptionNotifier.notify_exception(exception)
    assert_equal notifier1_calls, 1
    assert_equal notifier2_calls, 1

    ExceptionNotifier.notify_exception(exception, {:notifiers => :notifier1})
    assert_equal notifier1_calls, 2
    assert_equal notifier2_calls, 1

    ExceptionNotifier.notify_exception(exception, {:notifiers => :notifier2})
    assert_equal notifier1_calls, 2
    assert_equal notifier2_calls, 2

    ExceptionNotifier.unregister_exception_notifier(:notifier1)
    ExceptionNotifier.unregister_exception_notifier(:notifier2)
    assert_equal ExceptionNotifier.notifiers, [:email]
  end

  test "should ignore exception if satisfies conditional ignore" do
    ExceptionNotifier.stubs(:skip_notification_for_grouping_error?).returns(false)

    env = "production"
    ExceptionNotifier.ignore_if do |exception, options|
      env != "production"
    end

    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception = StandardError.new

    ExceptionNotifier.notify_exception(exception, {:notifiers => :test})
    assert_equal @notifier_calls, 1

    env = "development"
    ExceptionNotifier.notify_exception(exception, {:notifiers => :test})
    assert_equal @notifier_calls, 1

    ExceptionNotifier.clear_ignore_conditions!
  end

  test "should not send notification if one of ignored exceptions" do
    ExceptionNotifier.stubs(:skip_notification_for_grouping_error?).returns(false)

    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception = StandardError.new

    ExceptionNotifier.notify_exception(exception, {:notifiers => :test})
    assert_equal @notifier_calls, 1

    ExceptionNotifier.notify_exception(exception, {:notifiers => :test, :ignore_exceptions => 'StandardError' })
    assert_equal @notifier_calls, 1
  end

  test "should grouping errors if same exception and backtrace" do
    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception = Proc.new do |i|
      e = ExceptionOne.new("error#{i}")
      e.stubs(:backtrace).returns(["/file/path:1"])
      e
    end

    1000.times { |i| ExceptionNotifier.notify_exception(exception.call(i), {:notifiers => :test}) }

    key = Zlib.crc32("ExceptionOne\npath:/file/path:1")
    assert_equal 1000, Rails.cache.read("exception:#{key}")
    assert_equal 7, @notifier_calls
  end

  test "should grouping errors if same exception and message" do
    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception = Proc.new do |i|
      e = ExceptionOne.new("error")
      e.stubs(:backtrace).returns(["/file/path:#{i}"])
      e
    end

    1000.times { |i| ExceptionNotifier.notify_exception(exception.call(i), {:notifiers => :test}) }

    key = Zlib.crc32("ExceptionOne\nmessage:error")
    assert_equal 1000, Rails.cache.read("exception:#{key}")
    assert_equal 7, @notifier_calls
  end

  test "should not group errors if different exception" do
    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception_one = ExceptionOne.new
    exception_one.stubs(:backtrace).returns(["/file/path:1"])
    exception_two = ExceptionTwo.new
    exception_two.stubs(:backtrace).returns(["/file/path:1"])

    ExceptionNotifier.notify_exception(exception_one, {:notifiers => :test})
    ExceptionNotifier.notify_exception(exception_two, {:notifiers => :test})
    key1 = Zlib.crc32("ExceptionOne\npath:/file/path:1")
    key2 = Zlib.crc32("ExceptionTwo\npath:/file/path:1")

    assert_equal 1, Rails.cache.read("exception:#{key1}")
    assert_equal 1, Rails.cache.read("exception:#{key2}")
    assert_equal 2, @notifier_calls
  end

  test "should not group errors if same exception with different backtrace and message" do
    ExceptionNotifier.register_exception_notifier(:test, @test_notifier)

    exception = Proc.new do |i|
      e = ExceptionOne.new("error#{i}")
      e.stubs(:backtrace).returns(["/file/path:#{i}"])
      e
    end

    3.times { |i| ExceptionNotifier.notify_exception(exception.call(i), {:notifiers => :test}) }

    key1 = Zlib.crc32("ExceptionOne\nmessage:error0")
    key2 = Zlib.crc32("ExceptionOne\nmessage:error1")
    key3 = Zlib.crc32("ExceptionOne\nmessage:error2")

    assert_equal 1, Rails.cache.read("exception:#{key1}")
    assert_equal 1, Rails.cache.read("exception:#{key2}")
    assert_equal 1, Rails.cache.read("exception:#{key3}")
    assert_equal 3, @notifier_calls
  end
end
