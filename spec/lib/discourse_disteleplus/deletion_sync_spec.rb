# frozen_string_literal: true

require "rails_helper"

# Telegram never tells a bot about deletions, so the bridge copies its
# messages into a check channel: what Telegram can't find was deleted there.
RSpec.describe DiscourseDisteleplus::DeletionSync do
  fab!(:author, :user)

  let(:chat_id) { "-100555" }
  let(:check_chat_id) { "-100999" }
  let(:api) { instance_double(DiscourseDisteleplus::TelegramApi) }
  let(:gone_ids) { Set.new }
  let(:result) { DiscourseDisteleplus::TelegramApi::Result }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_telegram_chat_id = chat_id

    copy_id = 5000
    # Telegram as the docs have it: copyMessages skips what it can't find,
    # copyMessage says "message to copy not found"
    allow(api).to receive(:call) do |method, payload|
      case method
      when "copyMessages"
        found = payload[:message_ids].reject { |id| gone_ids.include?(id) }
        result.new(ok: true, result: found.map { { "message_id" => copy_id += 1 } })
      when "copyMessage"
        if gone_ids.include?(payload[:message_id])
          result.new(ok: false, description: "Bad Request: message to copy not found")
        else
          result.new(ok: true, result: { "message_id" => copy_id += 1 })
        end
      else
        result.new(ok: true, result: true)
      end
    end
  end

  def bridged!(tg_ids, source: :telegram, age: 10.minutes)
    message =
      DiscourseDisteleplus::Message.create!(user: author, raw: "hi", cooked: "<p>hi</p>", source:)
    Array(tg_ids).each do |id|
      DiscourseDisteleplus::MessageLink.create!(
        telegram_chat_id: chat_id.to_i,
        telegram_message_id: id,
        disteleplus_message_id: message.id,
        direction: source == :telegram ? :tg_to_discourse : :discourse_to_tg,
        kind: :text,
        created_at: age.ago,
      )
    end
    message
  end

  def sync
    described_class.new(chat_id:, check_chat_id:, api:).run
  end

  it "deletes here what was deleted on Telegram, and only that" do
    kept = (101..140).map { |id| bridged!(id) }
    deleted = bridged!(217)
    gone_ids << 217
    kept << bridged!(218)

    expect(sync).to eq([deleted])
    expect(deleted.reload).to be_deleted
    expect(kept.map(&:reload)).to all(satisfy { |m| !m.deleted? })
    expect(DiscourseDisteleplus::MessageLink.where(telegram_message_id: 217)).to be_empty
    # the copies are deleted from the check channel
    expect(api).to have_received(:call).with(
      "deleteMessages",
      a_hash_including(chat_id: check_chat_id),
    ).at_least(:once)
    # and nothing is sent back to Telegram for it
    expect(Jobs::DisteleplusSendToTelegram.jobs).to be_empty
  end

  it "deletes a forum message sent as several Telegram messages only when all are gone" do
    album = bridged!([301, 302], source: :discourse)
    gone_ids << 301
    expect(sync).to be_empty
    expect(album.reload).not_to be_deleted

    gone_ids << 302
    expect(sync).to eq([album])
  end

  it "leaves everything when Telegram answers with anything but not found" do
    message = bridged!(401)
    allow(api).to receive(:call).and_return(
      result.new(ok: false, description: "Bad Request: chat not found"),
    )
    expect(sync).to be_empty
    expect(message.reload).not_to be_deleted
  end

  it "keeps a message Telegram can't copy (a quiz, a service message)" do
    message = bridged!(501)
    allow(api).to receive(:call).with("copyMessages", anything).and_return(
      result.new(ok: true, result: []),
    )
    allow(api).to receive(:call).with("copyMessage", anything).and_return(
      result.new(ok: false, description: "Bad Request: message can't be copied"),
    )
    expect(sync).to be_empty
    expect(message.reload).not_to be_deleted
  end

  it "checks a week's older messages a twelfth at a time, and none older" do
    recent = bridged!(600)
    old = (601..612).map { |id| bridged!(id, age: 2.days) }
    ancient = bridged!(613, age: 8.days)
    gone_ids.merge([600, *601..613])

    now = Time.zone.now
    deleted = described_class.new(chat_id:, check_chat_id:, api:, now:).run
    expect(deleted).to include(recent)
    expect((deleted & old).size).to eq(1)
    expect(deleted).not_to include(ancient)
  end
end
