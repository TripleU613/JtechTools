# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordMirror::Backfill do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_mirror_enabled = true
    DiscourseDiscordMirror::MirrorThread.create!(
      topic_id: topic.id,
      category_id: category.id,
      discord_thread_id: "5",
      title_sent: topic.title,
      updated_at: 1.minute.from_now,
    )
    DiscourseDiscordMirror::MirrorMessage.create!(
      post_id: post.id,
      topic_id: topic.id,
      discord_message_id: "6",
      content_digest: "d",
    )
  end

  it "doesn't flag a mirrored topic that hasn't changed" do
    expect(described_class.stale_topic_ids).to be_empty
  end

  it "flags a topic once one of its mirrored posts is hidden, deleted or whispered" do
    post.update_columns(hidden: true)
    expect(described_class.stale_topic_ids).to eq([topic.id])

    post.update_columns(hidden: false, deleted_at: Time.zone.now)
    expect(described_class.stale_topic_ids).to eq([topic.id])

    post.update_columns(deleted_at: nil)
    PostCustomField.create!(
      post_id: post.id,
      name: DiscourseModCategories::Whisper.targets_field,
      value: "1",
    )
    expect(described_class.stale_topic_ids).to eq([topic.id])
  end

  it "flags a topic once it's unlisted, closed or moved" do
    topic.update_columns(visible: false)
    expect(described_class.stale_topic_ids).to eq([topic.id])
    topic.update_columns(visible: true, closed: true)
    expect(described_class.stale_topic_ids).to eq([topic.id])
  end

  it "walks topics oldest activity first and keeps its place" do
    older = Fabricate(:topic, category: category, bumped_at: 10.days.ago)
    topic.update_columns(bumped_at: 1.day.ago)
    expect(described_class.next_batch(30).map(&:id)).to eq([older.id, topic.id])
    described_class.advance(older)
    expect(described_class.next_batch(30).map(&:id)).to eq([topic.id])
  end
end
