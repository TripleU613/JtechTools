# frozen_string_literal: true

require "rails_helper"

# The header icon's badge counts messages that mention the reader, not every
# message: the conversation is busy, and a count for each one was noise.
RSpec.describe "Disteleplus header badge" do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other) { Fabricate(:user, trust_level: TrustLevel[1]) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_allowed_groups = Group::AUTO_GROUPS[:trust_level_1].to_s
    SiteSetting.disteleplus_bridge_bot_username = "telegram_bridge"
  end

  def say(raw)
    DiscourseDisteleplus::MessageService.new(actor: other).create!(
      raw: raw,
      bridge: false,
      notify: true,
    )
  end

  it "counts mentions, already there and arriving, and nothing else" do
    say("@#{member.username} are you there?")
    say("Morning, everyone")
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".disteleplus-header-icon__badge", text: "1")

    say("Anyone tried the new build?")
    say("@#{member.username} it's out")
    # 2, not 3: the plain message before it isn't counted
    expect(page).to have_css(".disteleplus-header-icon__badge", text: "2")
    expect(page).to have_no_css(".disteleplus-header-icon__badge", text: "3")
  end
end
