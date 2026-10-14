# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseTrustLevelFlair do
  def tl_group(level)
    Group.find(Group::AUTO_GROUPS[:"trust_level_#{level}"])
  end

  fab!(:newcomer) { Fabricate(:user, trust_level: TrustLevel[0]) }
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:leader) { Fabricate(:user, trust_level: TrustLevel[4]) }
  fab!(:club) { Fabricate(:group, flair_icon: "star") }

  before do
    Group.refresh_automatic_groups!
    (0..3).each { |level| tl_group(level).update!(flair_icon: "circle") }
    tl_group(4).update!(flair_icon: nil, flair_upload_id: nil)
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_trust_level_flair = true
  end

  it "gives everyone without a flair their highest trust level group's that has one" do
    described_class.sync!

    expect(newcomer.reload.flair_group_id).to eq(tl_group(0).id)
    expect(member.reload.flair_group_id).to eq(tl_group(2).id)
    # trust level 4 has no flair here, so the leader shows trust level 3's
    expect(leader.reload.flair_group_id).to eq(tl_group(3).id)
  end

  it "moves the flair it gave with the trust level, up and down" do
    described_class.sync!
    member.change_trust_level!(TrustLevel[3])
    described_class.sync!(user_ids: [member.id])
    expect(member.reload.flair_group_id).to eq(tl_group(3).id)

    member.change_trust_level!(TrustLevel[1])
    described_class.sync!(user_ids: [member.id])
    expect(member.reload.flair_group_id).to eq(tl_group(1).id)
  end

  it "leaves a flair someone picked, and no flair once they took this one off" do
    club.add(member)
    member.update!(flair_group_id: club.id)
    described_class.sync!
    expect(member.reload.flair_group_id).to eq(club.id)
    expect(newcomer.reload.flair_group_id).to eq(tl_group(0).id)

    newcomer.update!(flair_group_id: nil)
    described_class.sync!
    expect(newcomer.reload.flair_group_id).to be_nil
  end

  it "only touches the users it's asked about" do
    described_class.sync!(user_ids: [newcomer.id])
    expect(newcomer.reload.flair_group_id).to eq(tl_group(0).id)
    expect(member.reload.flair_group_id).to be_nil
  end

  it "does nothing while switched off" do
    SiteSetting.jtech_trust_level_flair = false
    described_class.sync!
    expect(newcomer.reload.flair_group_id).to be_nil

    SiteSetting.jtech_trust_level_flair = true
    SiteSetting.jtech_enabled = false
    described_class.sync!
    expect(newcomer.reload.flair_group_id).to be_nil
  end

  it "runs for someone whose trust level changes" do
    expect_enqueued_with(job: :jtech_trust_level_flair, args: { user_ids: [member.id] }) do
      Promotion.new(member).change_trust_level!(TrustLevel[3])
    end
  end
end
