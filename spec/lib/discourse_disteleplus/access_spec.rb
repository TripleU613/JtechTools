# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDisteleplus::Access do
  fab!(:admin)
  fab!(:moderator)
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:outsider) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:team) { Fabricate(:group).tap { |g| g.add(member) } }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_allowed_groups = team.id.to_s
  end

  describe ".allowed?" do
    it "admits admins and allowed-group members only" do
      expect(described_class.allowed?(admin)).to eq(true)
      expect(described_class.allowed?(member)).to eq(true)
      expect(described_class.allowed?(outsider)).to eq(false)
      expect(described_class.allowed?(nil)).to eq(false)
    end

    it "defaults to staff" do
      SiteSetting.remove_override!(:disteleplus_allowed_groups)
      expect(described_class.allowed?(moderator)).to eq(true)
      expect(described_class.allowed?(member)).to eq(false)
    end

    it "refuses everyone while disabled" do
      SiteSetting.disteleplus_enabled = false
      expect(described_class.allowed?(admin)).to eq(false)
    end

    it "refuses suspended and staged users" do
      member.update!(suspended_till: 1.day.from_now, suspended_at: Time.zone.now)
      expect(described_class.allowed?(member)).to eq(false)
      expect(described_class.allowed?(Fabricate(:user, staged: true))).to eq(false)
    end
  end

  describe ".allowed_users" do
    it "lists admins plus allowed-group members, excluding staged accounts" do
      team.add(Fabricate(:user, staged: true))
      expect(described_class.allowed_users.pluck(:id)).to contain_exactly(admin.id, member.id)
    end
  end

  describe "edit/delete" do
    let(:mine) { DiscourseDisteleplus::Message.create!(user: member, raw: "x", cooked: "<p>x</p>") }
    let(:telegram) do
      DiscourseDisteleplus::Message.create!(
        user: admin,
        raw: "x",
        cooked: "<p>x</p>",
        source: :telegram,
      )
    end

    it "lets authors and staff edit Discourse messages, nobody else" do
      expect(described_class.can_edit?(member, mine)).to eq(true)
      expect(described_class.can_edit?(admin, mine)).to eq(true)
      expect(described_class.can_edit?(Fabricate(:user, trust_level: TrustLevel[1]), mine)).to eq(
        false,
      )
    end

    it "never edits Telegram-origin messages from Discourse" do
      expect(described_class.can_edit?(admin, telegram)).to eq(false)
    end

    # deleted here, the bot deletes it on Telegram too
    it "lets staff delete Telegram-origin messages, and nobody else" do
      expect(described_class.can_delete?(admin, telegram)).to eq(true)
      expect(described_class.can_delete?(member, telegram)).to eq(false)
    end

    it "refuses deleted messages" do
      mine.update!(deleted_at: Time.zone.now)
      expect(described_class.can_edit?(member, mine)).to eq(false)
    end
  end

  it "is exposed through Guardian and the current-user serializer" do
    expect(Guardian.new(member).can_access_disteleplus?).to eq(true)
    expect(Guardian.new(outsider).can_access_disteleplus?).to eq(false)
    expect(Guardian.new(moderator).can_moderate_disteleplus?).to eq(false)
    team.add(moderator)
    expect(Guardian.new(moderator.reload).can_moderate_disteleplus?).to eq(true)

    json = CurrentUserSerializer.new(member, scope: Guardian.new(member), root: false).as_json
    expect(json[:can_access_disteleplus]).to eq(true)
  end
end
