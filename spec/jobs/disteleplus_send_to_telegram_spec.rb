# frozen_string_literal: true

require "rails_helper"

# Outbound behavior with TelegramApi stubbed: native message/link rows drive
# create/edit/delete/react routing, and every Telegram payload is asserted.
RSpec.describe Jobs::DisteleplusSendToTelegram do
  fab!(:author) { Fabricate(:user, username: "chatter", name: "Chatter Person") }
  let(:header) { "<a href=\"#{Discourse.base_url}/u/chatter\"><b>Chatter Person</b></a>" }

  let(:api) { instance_double(DiscourseDisteleplus::TelegramApi) }
  let(:chat_id) { "-100555" }
  let(:ok_result) do
    DiscourseDisteleplus::TelegramApi::Result.new(ok: true, result: { "message_id" => 321 })
  end
  let!(:message) do
    DiscourseDisteleplus::Message.create!(
      user: author,
      raw: "hi there",
      cooked: "<p>hi there</p>",
      source: :discourse,
    )
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_telegram_chat_id = chat_id
    SiteSetting.authorized_extensions = "jpg|jpeg|png|gif|ogg|webm|m4a|opus|mp3|pdf"

    allow(DiscourseDisteleplus::TelegramApi).to receive(:new).and_return(api)
    allow(api).to receive(:call).and_return(ok_result)
  end

  def link!(direction: :discourse_to_tg, kind: :text, tg_id: 321, message_id: message.id)
    DiscourseDisteleplus::MessageLink.create!(
      telegram_chat_id: chat_id.to_i,
      telegram_message_id: tg_id,
      disteleplus_message_id: message_id,
      direction: direction,
      kind: kind,
    )
  end

  def run(action, id = message.id)
    described_class.new.execute(action: action, message_id: id)
  end

  describe "create" do
    it "sends HTML text with the author prefix and records the link" do
      expect { run("create") }.to change { DiscourseDisteleplus::MessageLink.count }.by(1)
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(chat_id: chat_id, parse_mode: "HTML", text: "#{header}\nhi there"),
      )
      link = DiscourseDisteleplus::MessageLink.last
      expect(link.telegram_message_id).to eq(321)
      expect(link.disteleplus_message_id).to eq(message.id)
      expect(link).to be_discourse_to_tg
    end

    it "routes messages into the configured Telegram topic" do
      SiteSetting.disteleplus_chat_topic_id = 88
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(message_thread_id: 88),
      )
    end

    it "treats topic id 1 as General and omits the thread id" do
      SiteSetting.disteleplus_chat_topic_id = 1
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        satisfy { |payload| !payload.key?(:message_thread_id) },
      )
    end

    it "escapes HTML in the message body" do
      message.update!(raw: "<script>x & y</script>")
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(text: "#{header}\n&lt;script&gt;x &amp; y&lt;/script&gt;"),
      )
    end

    it "skips messages that are already linked (echo guard)" do
      link!
      run("create")
      expect(api).not_to have_received(:call)
    end

    it "ignores unknown message ids" do
      run("create", 0)
      expect(api).not_to have_received(:call)
    end

    context "with a voice note upload" do
      let(:voice_upload) do
        Fabricate(
          :upload,
          user: author,
          original_filename: "voice-note-20260828-152213.ogg",
          extension: "ogg",
          filesize: 40_000,
        )
      end
      let(:media_result) do
        DiscourseDisteleplus::TelegramApi::Result.new(ok: true, result: { "message_id" => 777 })
      end

      before do
        message.message_uploads.create!(upload: voice_upload)
        allow(DiscourseDisteleplus::TelegramUploadSender).to receive(:upload_io).and_return(
          StringIO.new("ogg"),
        )
        allow(api).to receive(:call_multipart).and_return(media_result)
      end

      it "delivers it as a Telegram voice bubble via sendVoice" do
        run("create")
        expect(api).to have_received(:call_multipart).with(
          "sendVoice",
          a_hash_including(chat_id: chat_id, caption: "#{header}\nhi there"),
          a_hash_including(
            file_field: "voice",
            filename: "voice-note-20260828-152213.ogg",
            mime: "audio/ogg",
          ),
        )
        link = DiscourseDisteleplus::MessageLink.last
        expect(link.telegram_message_id).to eq(777)
        expect(link).to be_kind_media
      end

      it "still routes plain audio through sendAudio" do
        # mp3 is not among the extensions the voice-note module authorizes
        # (it only adds recorder outputs), and Upload validates on fabricate.
        SiteSetting.authorized_extensions = "#{SiteSetting.authorized_extensions}|mp3"
        message.message_uploads.destroy_all
        message.message_uploads.create!(
          upload:
            Fabricate(
              :upload,
              user: author,
              original_filename: "song.mp3",
              extension: "mp3",
              filesize: 40_000,
            ),
        )
        run("create")
        # Not `anything` — that resolves to Mocha's matcher under Discourse's
        # harness and never matches on an rspec-mocks double.
        expect(api).to have_received(:call_multipart).with(
          "sendAudio",
          a_hash_including(chat_id: chat_id),
          a_hash_including(file_field: "audio", filename: "song.mp3"),
        )
      end

      it "sends only text when upload bridging is off" do
        SiteSetting.disteleplus_bridge_uploads = false
        run("create")
        expect(api).not_to have_received(:call_multipart)
        expect(api).to have_received(:call).with("sendMessage", a_hash_including(chat_id: chat_id))
      end
    end

    it "disables the link preview so the profile header never renders a bio card" do
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(link_preview_options: { is_disabled: true }),
      )
    end

    it "points the link preview at the first body URL instead of the profile" do
      message.update!(raw: "look https://example.com/a and https://example.com/b")
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(link_preview_options: { url: "https://example.com/a" }),
      )
    end

    it "threads Telegram replies via the link table" do
      parent =
        DiscourseDisteleplus::Message.create!(user: author, raw: "parent", cooked: "<p>parent</p>")
      link!(tg_id: 42, message_id: parent.id, direction: :tg_to_discourse)
      message.update!(reply_to: parent)
      run("create")
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(reply_to_message_id: 42),
      )
    end
  end

  describe "edit" do
    it "uses editMessageText for text links" do
      link!(kind: :text)
      run("edit")
      expect(api).to have_received(:call).with(
        "editMessageText",
        a_hash_including(message_id: 321, text: "#{header}\nhi there"),
      )
    end

    it "uses editMessageCaption for media links" do
      link!(kind: :media)
      run("edit")
      expect(api).to have_received(:call).with(
        "editMessageCaption",
        a_hash_including(message_id: 321, caption: "#{header}\nhi there"),
      )
    end

    it "ignores edits of unlinked messages" do
      run("edit")
      expect(api).not_to have_received(:call)
    end

    it "honors the disteleplus_bridge_edits toggle" do
      SiteSetting.disteleplus_bridge_edits = false
      link!(kind: :text)
      run("edit")
      expect(api).not_to have_received(:call)
    end
  end

  describe "react notices" do
    it "posts a reaction notice naming the reactor under the Telegram copy" do
      link!(tg_id: 321)
      described_class.new.execute(
        action: "react",
        message_id: message.id,
        reactor_id: author.id,
        emoji: "heart",
        reaction_action: "add",
      )
      expect(api).to have_received(:call).with(
        "sendMessage",
        a_hash_including(
          reply_to_message_id: 321,
          disable_notification: true,
          text: include("Chatter Person").and(include("reacted")),
        ),
      )
      expect(api).to have_received(:call).with(
        "setMessageReaction",
        a_hash_including(message_id: 321),
      )
    end

    it "stays quiet on removals and when notices are off" do
      link!(tg_id: 321)
      described_class.new.execute(
        action: "react",
        message_id: message.id,
        reactor_id: author.id,
        emoji: "heart",
        reaction_action: "remove",
      )
      SiteSetting.disteleplus_bridge_reaction_notices = false
      described_class.new.execute(
        action: "react",
        message_id: message.id,
        reactor_id: author.id,
        emoji: "heart",
        reaction_action: "add",
      )
      expect(api).not_to have_received(:call).with("sendMessage", kind_of(Hash))
    end
  end

  describe "delete" do
    it "deletes every linked Telegram message and removes the links" do
      link!(tg_id: 321)
      link!(tg_id: 322, kind: :media)
      expect { run("delete") }.to change { DiscourseDisteleplus::MessageLink.count }.by(-2)
      expect(api).to have_received(:call).with("deleteMessage", a_hash_including(message_id: 321))
      expect(api).to have_received(:call).with("deleteMessage", a_hash_including(message_id: 322))
    end

    # Deleting one side only: a message written on Telegram and deleted here
    # stayed on Telegram
    it "deletes the Telegram original of a message written on Telegram" do
      link!(direction: :tg_to_discourse, tg_id: 777)
      expect { run("delete") }.to change { DiscourseDisteleplus::MessageLink.count }.by(-1)
      expect(api).to have_received(:call).with("deleteMessage", a_hash_including(message_id: 777))
    end

    it "honors the disteleplus_bridge_deletes toggle" do
      SiteSetting.disteleplus_bridge_deletes = false
      link!(tg_id: 321)
      expect { run("delete") }.not_to change { DiscourseDisteleplus::MessageLink.count }
      expect(api).not_to have_received(:call)
    end
  end

  describe "react" do
    before { link! }

    def react!(user, emoji, at:)
      DiscourseDisteleplus::Reaction.create!(
        message: message,
        user: user,
        emoji: emoji,
        created_at: at,
        updated_at: at,
      )
    end

    it "mirrors the most recent Discourse reaction" do
      react!(author, "+1", at: 2.minutes.ago)
      react!(Fabricate(:user), "fire", at: 1.minute.ago)
      run("react")
      expect(api).to have_received(:call).with(
        "setMessageReaction",
        a_hash_including(message_id: 321, reaction: [{ type: "emoji", emoji: "🔥" }]),
      )
    end

    it "falls back to 👍 for unmapped emoji" do
      react!(author, "some_exotic_emoji", at: 1.minute.ago)
      run("react")
      expect(api).to have_received(:call).with(
        "setMessageReaction",
        a_hash_including(reaction: [{ type: "emoji", emoji: "👍" }]),
      )
    end

    it "clears the bot reaction when no reactions remain" do
      run("react")
      expect(api).to have_received(:call).with("setMessageReaction", a_hash_including(reaction: []))
    end
  end

  it "re-enqueues itself when Telegram rate-limits" do
    allow(api).to receive(:call).and_raise(DiscourseDisteleplus::TelegramApi::RateLimited.new(7))
    expect { run("create") }.to change { Jobs::DisteleplusSendToTelegram.jobs.size }.by(1)
    job = Jobs::DisteleplusSendToTelegram.jobs.last
    expect(job["args"].first).to include("action" => "create", "message_id" => message.id)
  end

  it "does nothing when the module is disabled" do
    SiteSetting.disteleplus_enabled = false
    run("create")
    expect(api).not_to have_received(:call)
  end
end
