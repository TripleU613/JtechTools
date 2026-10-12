# frozen_string_literal: true
# Jtech sub-plugin: Mod elections — the forum elects its moderators.
#
# On a calendar (every January, April, July and October by default)
# nominations open, then Vote Week, then an admin publishes the count.
# Members rank the candidates; the count is single transferable vote
# (lib/discourse_mod_elections/stv.rb) with each ballot weighted by its
# voter's trust level when nominations opened. Admins never run or vote.
# Publishing makes the winners moderators and takes moderator rights from
# the sitting moderators who weren't elected; former moderators keep trust
# level 4, locked, until they lose re-election too often.

register_asset "stylesheets/mod-elections.scss"

%w[
  check-to-slot
  far-comments
  list-ol
  arrow-up
  arrow-down
  xmark
  plus
  check
  pencil
  trophy
  users
  shield-halved
].each { |name| register_svg_icon(name) }

module ::DiscourseModElections
  STRIKES_FIELD = "mod_elections_strikes"
  LOG_TAG = "[jtech-tools mod-elections]"

  # Module switch AND the bundle master (jtech_enabled). The tick job and
  # every endpoint go through here.
  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.mod_elections_enabled
  end
end

require_relative "../lib/discourse_mod_elections/error"
require_relative "../lib/discourse_mod_elections/stv"
require_relative "../lib/discourse_mod_elections/schedule"
require_relative "../lib/discourse_mod_elections/state"
require_relative "../lib/discourse_mod_elections/eligibility"
require_relative "../lib/discourse_mod_elections/roll"
require_relative "../lib/discourse_mod_elections/notifier"
require_relative "../lib/discourse_mod_elections/disteleplus"
require_relative "../lib/discourse_mod_elections/announcer"
require_relative "../lib/discourse_mod_elections/nominations"
require_relative "../lib/discourse_mod_elections/voting"
require_relative "../lib/discourse_mod_elections/tally"
require_relative "../lib/discourse_mod_elections/seats"
require_relative "../lib/discourse_mod_elections/publisher"
require_relative "../lib/discourse_mod_elections/countback"
require_relative "../lib/discourse_mod_elections/lifecycle"
require_relative "../lib/discourse_mod_elections/ip_report"
require_relative "../lib/discourse_mod_elections/presenter"

after_initialize do
  register_user_custom_field_type(DiscourseModElections::STRIKES_FIELD, :integer)

  # The banner and the sidebar link: which step the election is at, and for
  # Vote Week whether this member can vote and has.
  add_to_serializer(
    :current_user,
    :mod_election,
    include_condition: -> do
      DiscourseModElections.enabled? && DiscourseModElections::State.active.present?
    end,
  ) { DiscourseModElections::Presenter.current_user_summary(object) }
end
