# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::DisteleplusSyncTelegramDeletions do
  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_telegram_chat_id = "-100555"
  end

  it "checks Telegram once a check channel is set" do
    SiteSetting.disteleplus_deletion_check_chat_id = "-100999"
    sync = instance_double(DiscourseDisteleplus::DeletionSync, run: [])
    allow(DiscourseDisteleplus::DeletionSync).to receive(:new).with(
      chat_id: "-100555",
      check_chat_id: "-100999",
    ).and_return(sync)

    described_class.new.execute({})
    expect(sync).to have_received(:run)
  end

  it "does nothing without a check channel, or with deletes not bridged" do
    allow(DiscourseDisteleplus::DeletionSync).to receive(:new)
    described_class.new.execute({})

    SiteSetting.disteleplus_deletion_check_chat_id = "-100999"
    SiteSetting.disteleplus_bridge_deletes = false
    described_class.new.execute({})

    expect(DiscourseDisteleplus::DeletionSync).not_to have_received(:new)
  end
end
