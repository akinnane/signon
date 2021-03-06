require "ipaddr"

class EventLog < ActiveRecord::Base
  deprecated_columns :event

  LOCKED_DURATION = "#{Devise.unlock_in / 1.hour} #{'hour'.pluralize(Devise.unlock_in / 1.hour)}".freeze

  EVENTS = [
    ACCOUNT_LOCKED = LogEntry.new(id: 1, description: "Password verification failed too many times, account locked for #{LOCKED_DURATION}"),
    ACCOUNT_SUSPENDED = LogEntry.new(id: 2, description: "Account suspended", require_initiator: true),
    ACCOUNT_UNSUSPENDED = LogEntry.new(id: 3, description: "Account unsuspended", require_initiator: true),
    ACCOUNT_AUTOSUSPENDED = LogEntry.new(id: 4, description: "Account auto-suspended"),
    MANUAL_ACCOUNT_UNLOCK = LogEntry.new(id: 5, description: "Manual account unlock", require_initiator: true),
    PASSWORD_RESET_REQUEST = LogEntry.new(id: 7, description: "Password reset request"),
    PASSWORD_RESET_LOADED = LogEntry.new(id: 8, description: "Password reset page loaded"),
    PASSWORD_RESET_FAILURE = LogEntry.new(id: 9, description: "Password reset attempt failure"),
    SUCCESSFUL_PASSWORD_CHANGE = LogEntry.new(id: 10, description: "Successful password change"),
    SUCCESSFUL_LOGIN = LogEntry.new(id: 11, description: "Successful login"),
    UNSUCCESSFUL_LOGIN = LogEntry.new(id: 12, description: "Unsuccessful login"),
    SUSPENDED_ACCOUNT_AUTHENTICATED_LOGIN = LogEntry.new(id: 13, description: "Unsuccessful login attempt to a suspended account, with the correct username and password"),
    UNSUCCESSFUL_PASSWORD_CHANGE = LogEntry.new(id: 14, description: "Unsuccessful password change"),
    EMAIL_CHANGED = LogEntry.new(id: 15, description: "Email changed", require_initiator: true),
    EMAIL_CHANGE_INITIATED = LogEntry.new(id: 16, description: "Email change initiated"),
    EMAIL_CHANGE_CONFIRMED = LogEntry.new(id: 17, description: "Email change confirmed"),
    TWO_STEP_ENABLED = LogEntry.new(id: 18, description: "2-step verification enabled"),
    TWO_STEP_RESET = LogEntry.new(id: 19, description: "2-step verification reset"),
    TWO_STEP_ENABLE_FAILED = LogEntry.new(id: 20, description: "2-step verification setup failed"),
    TWO_STEP_VERIFIED = LogEntry.new(id: 21, description: "2-step verification successful"),
    TWO_STEP_VERIFICATION_FAILED = LogEntry.new(id: 22, description: "2-step verification failed"),
    TWO_STEP_LOCKED = LogEntry.new(id: 23, description: "2-step verification failed too many times, account locked for #{LOCKED_DURATION}"),
    TWO_STEP_CHANGED = LogEntry.new(id: 24, description: "2-step verification phone changed"),
    TWO_STEP_CHANGE_FAILED = LogEntry.new(id: 25, description: "2-step verification phone change failed"),
    TWO_STEP_PROMPT_DEFERRED = LogEntry.new(id: 26, description: "2-step prompt deferred"),
    API_USER_CREATED = LogEntry.new(id: 27, description: "Account created", require_initiator: true),
    ACCESS_TOKEN_REGENERATED = LogEntry.new(id: 28, description: "Access token re-generated", require_application: true),
    ACCESS_TOKEN_GENERATED = LogEntry.new(id: 29, description: "Access token generated", require_application: true, require_initiator: true),
    ACCESS_TOKEN_REVOKED = LogEntry.new(id: 30, description: "Access token revoked", require_application: true, require_initiator: true),
    PASSWORD_RESET_LOADED_BUT_TOKEN_EXPIRED = LogEntry.new(id: 31, description: "Password reset page loaded but the token has expired"),
    SUCCESSFUL_PASSWORD_RESET = LogEntry.new(id: 32, description: "Password reset successfully"),
    ROLE_CHANGED = LogEntry.new(id: 33, description: "Role changed", require_initiator: true),
    ACCOUNT_UPDATED = LogEntry.new(id: 34, description: "Account updated", require_initiator: true),
    PERMISSIONS_ADDED = LogEntry.new(id: 35, description: "Permissions added", require_initiator: true),
    PERMISSIONS_REMOVED = LogEntry.new(id: 36, description: "Permissions removed", require_initiator: true),
    ACCOUNT_INVITED = LogEntry.new(id: 37, description: "Account was invited", require_initiator: true),

    # We no longer expire passwords, but we keep this event for history purposes
    PASSWORD_EXPIRED = LogEntry.new(id: 6, description: "Password expired"),
  ].freeze

  EVENTS_REQUIRING_INITIATOR = EVENTS.select(&:require_initiator?)
  EVENTS_REQUIRING_APPLICATION = EVENTS.select(&:require_application?)

  VALID_OPTIONS = %i[initiator application application_id trailing_message ip_address user_agent_id].freeze

  validates :uid, presence: true
  validates_presence_of :event_id
  validate :validate_event_mappable
  validates_presence_of :initiator_id,   if: Proc.new { |event_log| EVENTS_REQUIRING_INITIATOR.include? event_log.entry }
  validates_presence_of :application_id, if: Proc.new { |event_log| EVENTS_REQUIRING_APPLICATION.include? event_log.entry }

  belongs_to :initiator, class_name: "User"
  belongs_to :application, class_name: "Doorkeeper::Application"
  belongs_to :user_agent

  delegate :user_agent_string, to: :user_agent

  def event
    entry.description
  end

  def entry
    EVENTS.detect { |event| event.id == event_id }
  end

  def ip_address_string
    self.class.convert_integer_to_ip_address(self.ip_address)
  end

  def send_to_splunk(*)
    return unless ENV['SPLUNK_EVENT_LOG_ENDPOINT_URL'] && ENV['SPLUNK_EVENT_LOG_ENDPOINT_HEC_TOKEN']

    event = {
      id: self.id,
      uid: self.uid,
      created_at: self.created_at,
      initiator_name: self.initiator&.name,
      application_name: self.application&.name,
      trailing_message: self.trailing_message,
      event: self.event,
      ip_address: (self.ip_address_string if self.ip_address.present?),
      user_agent: self.user_agent&.user_agent_string
    }

    conn = Faraday.new(ENV['SPLUNK_EVENT_LOG_ENDPOINT_URL'])
    conn.post do |request|
      request.headers['Content-Type'] = 'application/json'
      request.headers['Authorization'] = "Splunk #{ENV['SPLUNK_EVENT_LOG_ENDPOINT_HEC_TOKEN']}"
      request.body = event.to_json
    end
  end

  def self.record_event(user, event, options = {})
    if options[:ip_address]
      options[:ip_address] = convert_ip_address_to_integer(options[:ip_address])
    end
    attributes = {
      uid: user.uid,
      event_id: event.id
    }.merge!(options.slice(*VALID_OPTIONS))

    event_log_entry = EventLog.create!(attributes)

    SplunkLogStreamingJob.perform_later(event_log_entry.id)

    event_log_entry
  end

  def self.record_email_change(user, email_was, email_is, initiator = user)
    event = user == initiator ? EMAIL_CHANGE_INITIATED : EMAIL_CHANGED
    record_event(user, event, initiator: initiator, trailing_message: "from #{email_was} to #{email_is}")
  end

  def self.record_role_change(user, previous_role, new_role, initiator)
    record_event(user, ROLE_CHANGED, initiator: initiator, trailing_message: "from #{previous_role} to #{new_role}")
  end

  def self.record_account_invitation(user, initiator)
    record_event(user, ACCOUNT_INVITED, initiator: initiator)
  end

  def self.for(user)
    EventLog.order('created_at DESC').where(uid: user.uid)
  end

  def self.convert_ip_address_to_integer(ip_address_string)
    IPAddr.new(ip_address_string).to_i
  end

  def self.convert_integer_to_ip_address(integer)
    if integer.to_s.length == 38
      # IPv6 address
      IPAddr.new(integer, Socket::AF_INET6).to_s
    else
      # IPv4 address
      IPAddr.new(integer, Socket::AF_INET).to_s
    end
  end

private

  def validate_event_mappable
    unless entry
      errors.add(:event_id, "must have a corresponding `LogEntry` for #{event_id}")
    end
  end
end
