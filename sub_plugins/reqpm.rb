# frozen_string_literal: true
# Jtech sub-plugin: REQ-PM — exchange contact details instead of messaging.
#
# The forum has no private messages. REQ-PM is how members still reach each
# other: everyone keeps a small "contact card" (phone, text, WhatsApp,
# email, website, … or their own custom ones), and can
#
#   * send someone selected details from it, or
#   * request someone's details — that person picks which ones (if any) to
#     send back.
#
# There is no free text anywhere in the exchange, so it cannot turn into a
# private message channel. Values are encrypted at rest and are only ever
# returned to their owner and to the people the owner chose; staff get no
# view of them, not through the UI, the API, or impersonation.

register_asset "stylesheets/reqpm.scss"

%w[
  address-card
  id-card
  phone
  comment-sms
  envelope
  globe
  fab-whatsapp
  fab-telegram
  fab-signal-messenger
  fab-discord
  hand
  paper-plane
  user-lock
  lock
  copy
  arrow-up-right-from-square
  chevron-up
  chevron-down
  pencil
  trash-can
  plus
  check
  xmark
  clock
  inbox
  handshake
  shield-halved
  star
  far-face-smile
  comment-dots
  circle-info
].each { |name| register_svg_icon(name) }

# Contact details arrive nested under `reqpm_contact`; masking the key keeps
# them out of the Rails request log and error reports. Set at load time so
# it is in place before the first request builds its parameter filter.
Rails.application.config.filter_parameters += [:reqpm_contact]

module ::DiscourseReqpm
  ALLOW_REQUESTS_FIELD = "reqpm_allow_requests"
  SETUP_SNOOZED_UNTIL_FIELD = "reqpm_setup_snoozed_until"
  SETUP_DECLINED_FIELD = "reqpm_setup_declined"
  LOG_TAG = "[jtech-tools reqpm]"

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.reqpm_enabled
  end

  # Everything REQ-PM holds about a user, in both directions. Used when an
  # account is anonymized; deleting a user cascades at the database level.
  def self.purge_user!(user)
    return if user.nil?
    Share.where(owner_id: user.id).or(Share.where(recipient_id: user.id)).delete_all
    ContactMethod.where(user_id: user.id).delete_all
    Request.where(requester_id: user.id).or(Request.where(target_id: user.id)).delete_all
    user.custom_fields.delete(ALLOW_REQUESTS_FIELD)
    user.custom_fields.delete(SETUP_SNOOZED_UNTIL_FIELD)
    user.custom_fields.delete(SETUP_DECLINED_FIELD)
    user.save_custom_fields(true)
  end
end

require_relative "../lib/discourse_reqpm/crypto"
require_relative "../lib/discourse_reqpm/kinds"
require_relative "../lib/discourse_reqpm/policy"
require_relative "../lib/discourse_reqpm/setup"
require_relative "../lib/discourse_reqpm/notifier"
require_relative "../lib/discourse_reqpm/presenter"
require_relative "../lib/discourse_reqpm/exchange"

after_initialize do
  register_user_custom_field_type(DiscourseReqpm::ALLOW_REQUESTS_FIELD, :boolean)
  register_user_custom_field_type(DiscourseReqpm::SETUP_DECLINED_FIELD, :boolean)
  register_user_custom_field_type(DiscourseReqpm::SETUP_SNOOZED_UNTIL_FIELD, :string)

  # What the client needs to show the button, the badge and the setup
  # prompt. Counts and flags only.
  add_to_serializer(:current_user, :reqpm, include_condition: -> { DiscourseReqpm.enabled? }) do
    DiscourseReqpm::Presenter.current_user_summary(object)
  end

  # Whether the REQ-PM button belongs on this person's card or profile at
  # all. Says nothing about whether they accept requests from the viewer.
  # Also on the hidden-profile serializer core swaps in for new or private
  # profiles — those members can still be reached this way.
  %i[user_card hidden_profile].each do |serializer|
    add_to_serializer(
      serializer,
      :reqpm_available,
      include_condition: -> do
        DiscourseReqpm.enabled? && scope.user.present? && scope.user.id != object.id
      end,
    ) { DiscourseReqpm::Policy.can_use?(object) }
  end

  on(:user_anonymized) do |args|
    DiscourseReqpm.purge_user!(args[:user])
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseReqpm::LOG_TAG} purge on anonymize failed: #{e.message}")
  end
end
