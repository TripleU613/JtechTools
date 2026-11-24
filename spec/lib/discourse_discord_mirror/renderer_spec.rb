# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordMirror::Renderer do
  fab!(:post) { Fabricate(:post, cooked: "<p>Hello <strong>there</strong></p>") }

  it "keeps every part within Discord's 2,000 characters" do
    long = (1..400).map { |i| "<p>Paragraph #{i} with some words in it</p>" }.join
    post.update!(cooked: long)
    parts = described_class.parts(post)
    expect(parts.size).to be <= described_class::MAX_PARTS
    expect(parts.map(&:length)).to all(be <= described_class::MESSAGE_LIMIT)
    expect(parts.last).to include("Read the whole post on JTech Forums")
  end

  it "ends with a link back to the post and its original time" do
    text = described_class.parts(post).last
    expect(text).to include("**there**")
    expect(text).to include("(<#{post.full_url}>)")
    expect(text).to include("<t:#{post.created_at.to_i}:f>")
  end

  it "shows images as bare links so Discord embeds them" do
    post.update!(cooked: %(<p><img src="https://example.com/a.png" alt="phone"></p>))
    expect(described_class.parts(post).first).to include("https://example.com/a.png")
    expect(described_class.parts(post).first).not_to include("![")
  end

  it "avoids the words Discord won't accept in a webhook name" do
    user = Fabricate.build(:user, username: "DiscordClyde")
    expect(described_class.username(user)).to eq("d1scordclyd3")
  end

  it "fits topic titles into a thread name" do
    topic = Fabricate.build(:topic, title: "A" * 150)
    expect(described_class.thread_name(topic).length).to eq(described_class::THREAD_NAME_LIMIT)
  end
end
