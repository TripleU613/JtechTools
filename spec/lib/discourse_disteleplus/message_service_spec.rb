# frozen_string_literal: true

require "rails_helper"

# The single mutation path: persistence, cooking, upload ownership, replies,
# soft deletion, reactions, read cursor, realtime publication, notification
# fan-out and outbound Telegram enqueueing.
RSpec.describe DiscourseDisteleplus::MessageService do
  fab!(:admin)
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:outsider) { Fabricate(:user, trust_level: TrustLevel[0]) }

  let(:messages) { DiscourseDisteleplus::Message }
  let(:outbound) { Jobs::DisteleplusSendToTelegram.jobs }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.disteleplus_enabled = true
    SiteSetting.disteleplus_allowed_groups = Group::AUTO_GROUPS[:trust_level_1].to_s
    SiteSetting.disteleplus_bridge_bot_username = "telegram_bridge"
  end

  def service(actor = member, **opts)
    described_class.new(actor: actor, **opts)
  end

  describe "#create!" do
    it "cooks server-side, publishes, notifies and enqueues the outbound job" do
      published =
        MessageBus.track_publish(DiscourseDisteleplus::Publisher::CHANNEL) do
          @message = service.create!(raw: "**hi** <script>x</script>")
        end
      expect(@message).to be_source_discourse
      expect(@message.cooked).to include("<strong>hi</strong>")
      expect(@message.cooked).not_to include("<script>")

      expect(published.length).to eq(1)
      expect(published.first.data[:type]).to eq("created")
      expect(published.first.user_ids).to contain_exactly(admin.id, member.id, other.id)

      expect(outbound.size).to eq(1)
      expect(outbound.last["args"].first).to include(
        "action" => "create",
        "message_id" => @message.id,
      )

      # No @mention → no notification; the unread badge is the signal.
      expect(Notification.where(notification_type: Notification.types[:custom]).count).to eq(0)
    end

    it "refuses actors outside the allowed groups" do
      expect { service(outsider) }.to raise_error(Discourse::InvalidAccess)
    end

    it "refuses an empty message" do
      expect { service.create!(raw: "  ") }.to raise_error(described_class::Error)
    end

    it "accepts upload-only messages owned by the actor" do
      upload = Fabricate(:upload, user: member)
      message = service.create!(raw: "", upload_ids: [upload.id])
      expect(message.uploads).to eq([upload])
    end

    it "refuses uploads owned by someone else" do
      upload = Fabricate(:upload, user: other)
      expect { service.create!(raw: "x", upload_ids: [upload.id]) }.to raise_error(
        Discourse::InvalidAccess,
      )
    end

    it "refuses unknown uploads" do
      expect { service.create!(raw: "x", upload_ids: [0, 999_999]) }.to raise_error(
        described_class::Error,
      )
    end

    it "links replies and rejects missing targets" do
      parent = service.create!(raw: "parent")
      reply = service.create!(raw: "child", reply_to_id: parent.id)
      expect(reply.reply_to).to eq(parent)
      expect { service.create!(raw: "x", reply_to_id: 999_999) }.to raise_error(
        described_class::Error,
      )
    end

    it "does not bridge or notify Telegram-origin messages" do
      message =
        service(admin, bypass_access: true).create!(
          raw: "from tg",
          source: :telegram,
          external_sender_name: " Zev ",
          bridge: false,
        )
      expect(message.external_sender_name).to eq("Zev")
      expect(outbound).to be_empty
    end
  end

  describe "#update!" do
    let!(:message) { service.create!(raw: "before") }

    it "edits the author's own message and bridges the edit" do
      outbound.clear
      service.update!(message, raw: "after")
      message.reload
      expect(message.raw).to eq("after")
      expect(message.edited_at).to be_present
      expect(outbound.last["args"].first).to include("action" => "edit")
    end

    it "lets staff edit, refuses other members" do
      expect { service(other).update!(message, raw: "nope") }.to raise_error(
        Discourse::InvalidAccess,
      )
      service(admin).update!(message, raw: "mod edit")
      expect(message.reload.raw).to eq("mod edit")
    end

    it "refuses Telegram-origin messages" do
      message.update!(source: :telegram)
      expect { service(admin).update!(message, raw: "x") }.to raise_error(Discourse::InvalidAccess)
    end
  end

  describe "#delete!" do
    let!(:message) do
      service.create!(raw: "bye", upload_ids: [Fabricate(:upload, user: member).id])
    end

    it "soft-deletes, strips content, and bridges the delete" do
      service.react!(message, emoji: "heart", action: :add)
      outbound.clear
      service.delete!(message)
      message.reload
      expect(message).to be_deleted
      expect(message.raw).to eq("")
      expect(message.uploads).to be_empty
      expect(message.reactions).to be_empty
      expect(outbound.last["args"].first).to include("action" => "delete")
    end

    it "keeps reply structure of children" do
      child = service(other).create!(raw: "re", reply_to_id: message.id)
      service.delete!(message)
      expect(child.reload.reply_to).to eq(message)
    end

    it "refuses other members" do
      expect { service(other).delete!(message) }.to raise_error(Discourse::InvalidAccess)
    end

    # Deleting one side only left the message on the other: a message written
    # on Telegram, deleted here, goes on Telegram too
    it "bridges the delete of a message written on Telegram" do
      from_telegram = service(admin).create!(raw: "from tg", source: :telegram, bridge: false)
      outbound.clear
      service(admin).delete!(from_telegram)
      expect(outbound.last["args"].first).to include(
        "action" => "delete",
        "message_id" => from_telegram.id,
      )
    end
  end

  describe "#react!" do
    let!(:message) { service.create!(raw: "react to me") }

    it "adds once, removes, normalizes, and bridges" do
      outbound.clear
      service(other).react!(message, emoji: ":fire:", action: :add)
      service(other).react!(message, emoji: "fire", action: :add)
      expect(message.reactions.pluck(:emoji)).to eq(["fire"])
      expect(outbound.last["args"].first).to include("action" => "react")

      service(other).react!(message, emoji: "fire", action: :remove)
      expect(message.reactions.count).to eq(0)
    end

    it "rejects garbage emoji names and deleted messages" do
      expect { service.react!(message, emoji: "<b>", action: :add) }.to raise_error(
        described_class::Error,
      )
      service.delete!(message)
      expect { service.react!(message, emoji: "fire", action: :add) }.to raise_error(
        described_class::Error,
      )
    end
  end

  describe "#mark_read!" do
    it "advances monotonically and clears matching notifications" do
      first = service(other).create!(raw: "one @#{member.username}")
      second = service(other).create!(raw: "two @#{member.username}")
      expect(Notification.where(user_id: member.id, read: false).count).to eq(2)

      state = service.mark_read!(second.id)
      expect(state.last_read_message_id).to eq(second.id)
      expect(Notification.where(user_id: member.id, read: false).count).to eq(0)

      expect(service.mark_read!(first.id).last_read_message_id).to eq(second.id)
      expect(service.mark_read!(999_999)).to be_nil
    end
  end

  describe "notifications" do
    it "notifies only @mentioned allowed users, never the author or the bot" do
      bot = DiscourseDisteleplus.bot_user
      service.create!(
        raw:
          "hello @#{other.username} and @#{admin.username} and @#{bot.username} and @#{outsider.username}",
      )
      message = DiscourseDisteleplus::Message.last
      ids = Notification.where(notification_type: Notification.types[:custom]).pluck(:user_id)
      expect(ids).to contain_exactly(other.id, admin.id),
      "cooked=#{message.cooked.inspect} mentioned=#{DiscourseDisteleplus::Notifier.mentioned_user_ids(message).inspect} allowed=#{DiscourseDisteleplus::Access.allowed_users.pluck(:id).inspect}"
      expect(Notification.where(user_id: other.id).last.data).to include("mentioned you")
    end

    it "expands @group mentions to allowed members" do
      group = Fabricate(:group, name: "ops", mentionable_level: Group::ALIAS_LEVELS[:everyone])
      group.add(other)
      group.add(outsider)
      service.create!(raw: "heads up @ops")
      ids = Notification.where(notification_type: Notification.types[:custom]).pluck(:user_id)
      expect(ids).to contain_exactly(other.id)
    end

    it "respects the master toggle" do
      SiteSetting.disteleplus_force_channel_notifications = false
      service.create!(raw: "quiet @#{other.username}")
      expect(Notification.where(notification_type: Notification.types[:custom]).count).to eq(0)
    end

    it "queues web push only for mentioned, subscribed recipients" do
      PushSubscription.create!(user: other, data: { endpoint: "https://push.example/x" }.to_json)
      expect { service.create!(raw: "no mention here") }.not_to change {
        Jobs::DeliverPushNotification.jobs.size
      }
      expect { service.create!(raw: "push @#{other.username}") }.to change {
        Jobs::DeliverPushNotification.jobs.size
      }.by(1)
      payload = Jobs::DeliverPushNotification.jobs.last["args"].first["payload"]
      expect(payload["post_url"]).to start_with("/disteleplus#m")
      expect(payload).to include("username" => member.username)
    end
  end
end
