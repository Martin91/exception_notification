require 'logger'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/module/attribute_accessors'
require 'exception_notifier/base_notifier'

module ExceptionNotifier

  autoload :BacktraceCleaner, 'exception_notifier/modules/backtrace_cleaner'

  autoload :Notifier, 'exception_notifier/notifier'
  autoload :EmailNotifier, 'exception_notifier/email_notifier'
  autoload :CampfireNotifier, 'exception_notifier/campfire_notifier'
  autoload :HipchatNotifier, 'exception_notifier/hipchat_notifier'
  autoload :WebhookNotifier, 'exception_notifier/webhook_notifier'
  autoload :IrcNotifier, 'exception_notifier/irc_notifier'
  autoload :SlackNotifier, 'exception_notifier/slack_notifier'
  autoload :MattermostNotifier, 'exception_notifier/mattermost_notifier'

  class UndefinedNotifierError < StandardError; end

  # Define logger
  mattr_accessor :logger
  @@logger = Logger.new(STDOUT)

  # Define a set of exceptions to be ignored, ie, dont send notifications when any of them are raised.
  mattr_accessor :ignored_exceptions
  @@ignored_exceptions = %w{ActiveRecord::RecordNotFound Mongoid::Errors::DocumentNotFound AbstractController::ActionNotFound ActionController::RoutingError ActionController::UnknownFormat ActionController::UrlGenerationError}

  mattr_accessor :grouping_error
  @@grouping_error = false

  mattr_accessor :grouping_error_period
  @@grouping_error_period = 5.minutes

  mattr_accessor :send_grouped_error_trigger

  mattr_accessor :testing_mode
  @@testing_mode = false

  class << self
    # Store conditions that decide when exceptions must be ignored or not.
    @@ignores = []

    # Store notifiers that send notifications when exceptions are raised.
    @@notifiers = {}

    def testing_mode!
      self.testing_mode = true
    end

    def notify_exception(exception, options={})
      return false if ignored_exception?(options[:ignore_exceptions], exception)
      return false if ignored?(exception, options)
      return false if grouping_error && skip_notification_for_grouping_error?(exception, options)

      selected_notifiers = options.delete(:notifiers) || notifiers
      [*selected_notifiers].each do |notifier|
        fire_notification(notifier, exception, options.dup)
      end
      true
    end

    def register_exception_notifier(name, notifier_or_options)
      if notifier_or_options.respond_to?(:call)
        @@notifiers[name] = notifier_or_options
      elsif notifier_or_options.is_a?(Hash)
        create_and_register_notifier(name, notifier_or_options)
      else
        raise ArgumentError, "Invalid notifier '#{name}' defined as #{notifier_or_options.inspect}"
      end
    end
    alias add_notifier register_exception_notifier

    def unregister_exception_notifier(name)
      @@notifiers.delete(name)
    end

    def registered_exception_notifier(name)
      @@notifiers[name]
    end

    def notifiers
      @@notifiers.keys
    end

    # Adds a condition to decide when an exception must be ignored or not.
    #
    #   ExceptionNotifier.ignore_if do |exception, options|
    #     not Rails.env.production?
    #   end
    def ignore_if(&block)
      @@ignores << block
    end

    def clear_ignore_conditions!
      @@ignores.clear
    end

    private
    def ignored?(exception, options)
      @@ignores.any?{ |condition| condition.call(exception, options) }
    rescue Exception => e
      raise e if @@testing_mode

      logger.warn "An error occurred when evaluating an ignore condition. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
      false
    end

    def ignored_exception?(ignore_array, exception)
      (Array(ignored_exceptions) + Array(ignore_array)).map(&:to_s).include?(exception.class.name)
    end

    def fire_notification(notifier_name, exception, options)
      notifier = registered_exception_notifier(notifier_name)
      notifier.call(exception, options)
    rescue Exception => e
      raise e if @@testing_mode

      logger.warn "An error occurred when sending a notification using '#{notifier_name}' notifier. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
      false
    end

    def create_and_register_notifier(name, options)
      notifier_classname = "#{name}_notifier".camelize
      notifier_class = ExceptionNotifier.const_get(notifier_classname)
      notifier = notifier_class.new(options)
      register_exception_notifier(name, notifier)
    rescue NameError => e
      raise UndefinedNotifierError, "No notifier named '#{name}' was found. Please, revise your configuration options. Cause: #{e.message}"
    end

    def skip_notification_for_grouping_error?(exception, options)
      backtrace_based_key = "exception:#{Zlib.crc32("#{exception.class.name}\npath:#{exception.backtrace.try(:first)}")}"
      message_based_key = "exception:#{Zlib.crc32("#{exception.class.name}\nmessage:#{exception.message}")}"

      accumulated_errors_count = 1
      if count = Rails.cache.read(message_based_key)
        accumulated_errors_count = count + 1
        Rails.cache.write(message_based_key, accumulated_errors_count, expires_in: grouping_error_period)
      elsif count = Rails.cache.read(backtrace_based_key)
        accumulated_errors_count = count + 1
        Rails.cache.write(backtrace_based_key, accumulated_errors_count, expires_in: grouping_error_period)
      else    # new error group
        Rails.cache.write(backtrace_based_key, accumulated_errors_count, expires_in: grouping_error_period)
        Rails.cache.write(message_based_key, accumulated_errors_count, expires_in: grouping_error_period)
      end

      options[:accumulated_errors_count] = accumulated_errors_count
      if send_grouped_error_trigger.respond_to?(:call)
        !send_grouped_error_trigger.call(accumulated_errors_count)
      else
        !send_notification?(accumulated_errors_count)
      end
    end

    def send_notification?(count)
      # send notification when count is: 1, 3, 6, 9, 10, 100, 1000, ... 10**n
      return true if count == 1

      factor = count < 10 ? count.to_f / 3 : Math.log10(count)
      factor.to_i == factor       # true when factor is a integer
    end
  end
end
