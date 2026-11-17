# frozen_string_literal: true

require "rails_helper"

# End-to-end regression coverage for every path a whisper could leak through
# to someone outside its audience. Each example drives the real endpoint /
# PostCreator / job so a Discourse upgrade that reroutes a code path shows
# up here.
#
# Cast (all whispers live in one public topic):
#   moderator — staff, writes whispers
#   alice     — named in whisper_to_alice
#   bob       — named in whisper_to_bob (so a "topic participant" of the topic)
#   stranger  — named in nothing, watches the topic, can read everything public
RSpec.describe "Whisper leak matrix" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:alice) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:bob) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:stranger) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, user: author) }
  fab!(:op) { Fabricate(:post, topic: topic, user: author, raw: "The opening post of this topic.") }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:armed) { DiscourseModCategories::POST_WHISPER_ARMED_PARAM }

  let(:secret_a) { "alicesecretzebra" }
  let(:secret_b) { "bobsecretgiraffe" }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    Group.refresh_automatic_groups!
  end

  def whisper!(by: moderator, to: [], raw: nil, reply_to: nil, **extra)
    opts = {
      :topic_id => topic.id,
      :raw => raw || "A whisper that nobody else may read.",
      armed => "true",
      targets_field => to.map(&:id),
    }
    opts[:reply_to_post_number] = reply_to.post_number if reply_to
    PostCreator.create!(by, opts.merge(extra))
  end

  def reply!(by:, raw:, reply_to: nil, **extra)
    opts = { topic_id: topic.id, raw: raw }
    opts[:reply_to_post_number] = reply_to.post_number if reply_to
    PostCreator.create!(by, opts.merge(extra))
  end

  def whisper?(post)
    DiscourseModCategories::Whisper.whisper?(post.reload)
  end

  def stream_ids(user)
    user ? sign_in(user) : delete("/session/#{stranger.username}")
    get "/t/#{topic.id}.json"
    expect(response.status).to eq(200)
    response.parsed_body["post_stream"]["posts"].map { |p| p["id"] }
  end

  let!(:whisper_to_alice) { whisper!(to: [alice], raw: "Alice only: #{secret_a} is the code.") }
  let!(:whisper_to_bob) { whisper!(to: [bob], raw: "Bob only: #{secret_b} is the code.") }

  describe "whispers in the same topic" do
    it "are visible only to the people each one names" do
      expect(Guardian.new(alice).can_see_post?(whisper_to_alice)).to eq(true)
      expect(Guardian.new(alice).can_see_post?(whisper_to_bob)).to eq(false)
      expect(Guardian.new(bob).can_see_post?(whisper_to_bob)).to eq(true)
      expect(Guardian.new(bob).can_see_post?(whisper_to_alice)).to eq(false)
      expect(Guardian.new(stranger).can_see_post?(whisper_to_alice)).to eq(false)
      expect(Guardian.new(nil).can_see_post?(whisper_to_alice)).to eq(false)
      expect(Guardian.new(admin).can_see_post?(whisper_to_bob)).to eq(true)
    end

    it "keep that separation in the topic stream" do
      expect(stream_ids(alice)).to include(whisper_to_alice.id)
      expect(stream_ids(alice)).not_to include(whisper_to_bob.id)
      expect(stream_ids(bob)).not_to include(whisper_to_alice.id)
      expect(stream_ids(stranger)).not_to include(whisper_to_alice.id, whisper_to_bob.id)
    end

    it "keep that separation on the single-post endpoints" do
      sign_in(bob)
      get "/posts/#{whisper_to_alice.id}.json"
      expect(response.status).to eq(404)
      get "/posts/#{whisper_to_alice.id}/raw"
      expect(response.body).not_to include(secret_a)
      get "/raw/#{topic.id}"
      expect(response.body).not_to include(secret_a)
      get "/raw/#{topic.id}/#{whisper_to_alice.post_number}"
      expect(response.body).not_to include(secret_a)
      get "/t/#{topic.id}/posts.json", params: { post_ids: [whisper_to_alice.id] }
      expect(response.body).not_to include(secret_a)
      get "/t/#{topic.id}/excerpts.json", params: { post_ids: [whisper_to_alice.id] }
      expect(response.body).not_to include(secret_a)
      get "/t/#{topic.id}/print"
      expect(response.body).not_to include(secret_a)
    end
  end

  describe "switching the feature off" do
    it "keeps existing whispers private" do
      SiteSetting.mod_whisper_enabled = false
      expect(stream_ids(stranger)).not_to include(whisper_to_alice.id)
      expect(Guardian.new(bob).can_see_post?(whisper_to_alice)).to eq(false)
      expect(stream_ids(alice)).to include(whisper_to_alice.id)
    end

    it "keeps them private when the whole bundle is switched off" do
      SiteSetting.jtech_enabled = false
      expect(Guardian.new(stranger).can_see_post?(whisper_to_alice)).to eq(false)
    end
  end

  describe "replies and quotes" do
    it "turns a non-staff reply to a whisper into a whisper to the same people" do
      # No mod_whisper param at all: what the /dumb app or an API client sends.
      reply = reply!(by: alice, raw: "Replying to the code, thanks!", reply_to: whisper_to_alice)

      expect(whisper?(reply)).to eq(true)
      expect(Guardian.new(moderator).can_see_post?(reply)).to eq(true)
      expect(Guardian.new(alice).can_see_post?(reply)).to eq(true)
      expect(Guardian.new(bob).can_see_post?(reply)).to eq(false)
      expect(Guardian.new(stranger).can_see_post?(reply)).to eq(false)
    end

    it "turns a non-staff post that quotes a whisper into a whisper" do
      raw =
        "[quote=\"#{moderator.username}, post:#{whisper_to_alice.post_number}, topic:#{topic.id}\"]\n" \
          "#{secret_a}\n[/quote]\n\nquoting it publicly"
      post = reply!(by: alice, raw: raw)

      expect(whisper?(post)).to eq(true)
      expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
    end

    it "makes a quote of two whispers with different audiences staff-only" do
      raw =
        "[quote=\"x, post:#{whisper_to_alice.post_number}, topic:#{topic.id}\"]\na\n[/quote]\n" \
          "[quote=\"x, post:#{whisper_to_bob.post_number}, topic:#{topic.id}\"]\nb\n[/quote]\nboth"
      post = reply!(by: moderator, raw: raw)

      expect(whisper?(post)).to eq(true)
      expect(Guardian.new(alice).can_see_post?(post)).to eq(false)
      expect(Guardian.new(bob).can_see_post?(post)).to eq(false)
    end

    it "keeps a staff reply to a whisper private unless staff explicitly publish it" do
      inherited =
        reply!(by: moderator, raw: "Staff reply, no flag sent", reply_to: whisper_to_alice)
      expect(whisper?(inherited)).to eq(true)
      expect(Guardian.new(alice).can_see_post?(inherited)).to eq(true)
      expect(Guardian.new(stranger).can_see_post?(inherited)).to eq(false)

      public_reply =
        reply!(
          :by => moderator,
          :raw => "Deliberately public",
          :reply_to => whisper_to_alice,
          armed => "false",
        )
      expect(whisper?(public_reply)).to eq(false)

      # …and that public reply does not reveal who wrote the whisper.
      sign_in(stranger)
      get "/t/#{topic.id}.json"
      json = response.parsed_body["post_stream"]["posts"].find { |p| p["id"] == public_reply.id }
      expect(json).to be_present
      expect(json["reply_to_user"]).to be_nil
    end

    it "drops a crafted reply pointer at a whisper the author can't see" do
      post = reply!(by: stranger, raw: "What did they say?", reply_to: whisper_to_alice)

      expect(whisper?(post)).to eq(false)
      expect(post.reload.reply_to_post_number).to be_nil
      expect(post.reply_to_user_id).to be_nil
    end

    it "never lets a whisper raise the parent's public reply count" do
      parent = reply!(by: author, raw: "A public post people reply to")
      whisper!(to: [alice], reply_to: parent)
      expect(parent.reload.reply_count).to eq(0)

      sign_in(stranger)
      get "/posts/#{parent.id}/replies.json"
      expect(response.body).not_to include("nobody else may read")
      get "/posts/#{parent.id}/reply-ids.json"
      expect(response.parsed_body.map { |r| r["id"] }).to be_empty
    end
  end

  it "refuses to start a new topic with a whisper" do
    sign_in(moderator)
    post "/posts.json",
         params: {
           :title => "A brand new topic title here",
           :raw => "This first post would have been a whisper.",
           :category => category.id,
           armed => "true",
         }
    expect(response.status).to eq(400)
  end

  describe "notifications" do
    it "doesn't let anyone read another user's notifications through the type filter" do
      sign_in(stranger)
      get "/notifications.json", params: { username: alice.username, type: "custom" }
      expect(response.status).to eq(403)
      get "/notifications.json", params: { username: alice.username, type: "mod_notes" }
      expect(response.status).to eq(403)

      sign_in(alice)
      get "/notifications.json", params: { username: alice.username, type: "custom" }
      expect(response.status).to eq(200)
    end

    it "notifies the whisper's audience and nobody else, watchers included" do
      Jobs.run_immediately!
      TopicUser.change(
        stranger.id,
        topic.id,
        notification_level: TopicUser.notification_levels[:watching],
      )
      TopicUser.change(
        bob.id,
        topic.id,
        notification_level: TopicUser.notification_levels[:watching],
      )

      w = whisper!(to: [alice], raw: "watchers must not hear about this @#{stranger.username}")

      stranger_rows = Notification.where(user_id: stranger.id, topic_id: topic.id)
      expect(stranger_rows.where(post_number: w.post_number)).to be_empty
      expect(Notification.where(user_id: bob.id, post_number: w.post_number)).to be_empty
      expect(Notification.where(user_id: alice.id, post_number: w.post_number)).to exist
    end

    it "leaves whispers out of the previous-replies context of e-mails" do
      [stranger, alice].each do |u|
        u.user_option.update!(email_previous_replies: UserOption.previous_replies_type[:always])
      end
      public_post = reply!(by: author, raw: "A later public reply for the email")
      topic_user = TopicUser.find_or_create_by!(user: stranger, topic: topic)
      context = UserNotifications.get_context_posts(public_post, topic_user, stranger)
      expect(context.map(&:id)).to include(op.id)
      expect(context.map(&:id)).not_to include(whisper_to_alice.id, whisper_to_bob.id)

      alice_context =
        UserNotifications.get_context_posts(
          public_post,
          TopicUser.find_or_create_by!(user: alice, topic: topic),
          alice,
        )
      expect(alice_context.map(&:id)).to include(whisper_to_alice.id)
      expect(alice_context.map(&:id)).not_to include(whisper_to_bob.id)
    end

    it "leaves whispers out of digests and mailing-list selections" do
      SiteSetting.editing_grace_period = 0
      topic.update_columns(created_at: 1.day.ago)
      ids = Post.for_mailing_list(stranger, 1.year.ago).pluck(:id)
      expect(ids).not_to include(whisper_to_alice.id)
      expect(ids).to include(op.id)
    end
  end

  describe "live updates" do
    it "publishes whisper post messages to its audience only" do
      messages =
        MessageBus.track_publish("/topic/#{topic.id}") do
          whisper!(to: [alice], raw: "live update test whisper")
        end
      expect(messages).not_to be_empty
      messages.each do |m|
        expect(m.user_ids).to be_present
        expect(m.user_ids).to include(alice.id, moderator.id)
        expect(m.user_ids).not_to include(stranger.id, bob.id)
        expect(m.group_ids).to be_blank
      end
    end

    it "doesn't bump the topic on /latest for everyone" do
      Jobs.run_immediately!
      messages =
        MessageBus.track_publish("/latest") { whisper!(to: [alice], raw: "no latest bump please") }
      expect(messages).to be_empty
    end
  end

  describe "lists and feeds" do
    it "leaves whispers out of /posts.json and /posts.rss" do
      sign_in(stranger)
      get "/posts.json"
      expect(response.body).not_to include(secret_a)
      get "/posts.rss"
      expect(response.body).not_to include(secret_a)
    end

    it "leaves whispers out of the topic RSS feed" do
      get "/t/#{topic.slug}/#{topic.id}.rss"
      expect(response.body).not_to include(secret_a)
    end

    it "leaves whispers out of a group's activity posts" do
      group = Fabricate(:group, visibility_level: Group.visibility_levels[:public])
      group.add(moderator)
      sign_in(stranger)
      get "/groups/#{group.name}/posts.json"
      expect(response.status).to eq(200)
      expect(response.body).not_to include(secret_a)
      get "/groups/#{group.name}/posts.rss"
      expect(response.body).not_to include(secret_a)
    end

    it "leaves whispers out of the author's activity stream and summary" do
      sign_in(stranger)
      get "/user_actions.json", params: { username: moderator.username, filter: "4,5" }
      expect(response.body).not_to include(secret_a)
      get "/u/#{moderator.username}/summary.json"
      expect(response.body).not_to include(secret_a)
    end

    it "doesn't count whisper authors as topic participants" do
      sign_in(stranger)
      get "/t/#{topic.id}.json"
      participants = response.parsed_body.dig("details", "participants") || []
      expect(participants.map { |p| p["id"] }).not_to include(moderator.id)
    end

    it "keeps links inside whispers out of the public topic map" do
      whisper!(to: [alice], raw: "see https://secret-whisper-link.example.com/path for details")
      expect(TopicLink.where(topic_id: topic.id).pluck(:url).join).not_to include("secret-whisper")
    end

    it "keeps topic stats (last poster, posts count) from counting whispers" do
      topic.reload
      expect(topic.last_post_user_id).not_to eq(moderator.id)
      expect(topic.posts_count).to eq(1)
      expect(topic.highest_post_number).to eq(op.post_number)

      Topic.reset_highest(topic.id)
      topic.reload
      expect(topic.last_post_user_id).not_to eq(moderator.id)
      expect(topic.highest_post_number).to eq(op.post_number)
    end
  end

  describe "link previews" do
    it "never expands a whisper into a onebox" do
      url = "#{Discourse.base_url}/t/#{topic.slug}/#{topic.id}/#{whisper_to_alice.post_number}"
      expect(
        Oneboxer.preview(url, user_id: stranger.id, invalidate_oneboxes: true).to_s,
      ).not_to include(secret_a)

      linking = reply!(by: author, raw: "#{url}\n\nlook at this")
      CookedPostProcessor.new(linking.reload).post_process
      expect(linking.reload.cooked).not_to include(secret_a)
    end
  end

  describe "edit, history and moderation paths" do
    it "hides a whisper's revisions from people outside its audience" do
      SiteSetting.editing_grace_period = 0
      whisper_to_alice.revise(moderator, raw: "Alice only: edited #{secret_a} again.")
      expect(whisper_to_alice.reload.version).to be > 1

      sign_in(stranger)
      get "/posts/#{whisper_to_alice.id}/revisions/2.json"
      expect(response.status).to eq(403).or eq(404)
      get "/posts/#{whisper_to_alice.id}/revisions/latest.json"
      expect(response.status).to eq(403).or eq(404)
    end

    it "doesn't let edit-all-posts groups edit (or read back) a whisper they can't see" do
      SiteSetting.edit_all_post_groups = Group::AUTO_GROUPS[:trust_level_2].to_s
      expect(Guardian.new(stranger).can_edit_post?(whisper_to_alice)).to eq(false)

      sign_in(stranger)
      put "/posts/#{whisper_to_alice.id}.json", params: { post: { raw: "overwritten by stranger" } }
      expect(response.status).to eq(403).or eq(404)
      expect(whisper_to_alice.reload.raw).to include(secret_a)
    end

    it "refuses to pin a whisper and never renders a pinned whisper" do
      SiteSetting.mod_pin_post_enabled = true
      sign_in(moderator)
      put "/discourse-mod-categories/topic/#{topic.id}.json",
          params: {
            pinned_post_id: whisper_to_alice.id,
          }
      expect(response.status).to eq(400)

      topic.custom_fields[DiscourseModCategories::TOPIC_PINNED_POST_FIELD] = whisper_to_alice.id
      topic.save_custom_fields(true)
      sign_in(stranger)
      get "/t/#{topic.id}.json"
      expect(response.parsed_body["mod_topic_pinned_post"]).to be_nil
      expect(response.body).not_to include(secret_a)
    end
  end

  describe "the approval queue" do
    before { SiteSetting.approve_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_4].to_s }

    it "keeps a queued reply to a whisper a whisper once approved, and marks it private" do
      manager =
        NewPostManager.new(
          alice,
          topic_id: topic.id,
          raw: "queued whisper-back to the moderator",
          reply_to_post_number: whisper_to_alice.post_number,
        )
      result = manager.perform
      expect(result.action).to eq(:enqueued)

      reviewable = result.reviewable
      expect(DiscourseModCategories::Whisper.private_reviewable?(reviewable)).to eq(true)
      expect(DiscourseDisteleplus::Reports.excerpt_for(reviewable)).not_to include("queued whisper")

      reviewable.perform(admin, :approve_post)
      created = reviewable.reload.target
      expect(whisper?(created)).to eq(true)
      expect(Guardian.new(stranger).can_see_post?(created)).to eq(false)
      expect(Guardian.new(alice).can_see_post?(created)).to eq(true)
    end

    it "hides queued whispers from non-staff reviewers" do
      SiteSetting.enable_category_group_moderation = true
      reviewers = Fabricate(:group)
      reviewers.add(stranger)
      Fabricate(:category_moderation_group, category: category, group: reviewers)

      result =
        NewPostManager.new(
          alice,
          topic_id: topic.id,
          raw: "queued whisper-back to the moderator",
          reply_to_post_number: whisper_to_alice.post_number,
        ).perform
      expect(result.action).to eq(:enqueued)

      expect(Reviewable.viewable_by(stranger).to_a.map(&:id)).not_to include(result.reviewable.id)
      expect(Reviewable.viewable_by(moderator).to_a.map(&:id)).to include(result.reviewable.id)

      # Sanity: a queued non-whisper IS visible to the same reviewer.
      plain =
        NewPostManager.new(
          alice,
          topic_id: topic.id,
          raw: "an ordinary queued public reply",
        ).perform
      expect(Reviewable.viewable_by(stranger).to_a.map(&:id)).to include(plain.reviewable.id)
    end
  end

  describe "the Telegram bridge" do
    before do
      SiteSetting.disteleplus_forum_post_notifications_enabled = true
      SiteSetting.disteleplus_forum_post_first_post_only = false
    end

    it "never announces or mirrors a whisper" do
      expect(DiscourseDisteleplus::ForumUploadPolicy.eligible?(whisper_to_alice)).to eq(false)
      expect(DiscourseDisteleplus::ForumUploadPolicy.eligible_scope.pluck(:id)).not_to include(
        whisper_to_alice.id,
      )
      public_post = reply!(by: author, raw: "public post for the bridge")
      expect(DiscourseDisteleplus::ForumUploadPolicy.eligible?(public_post)).to eq(true)
      expect(DiscourseDisteleplus::ForumPostNotifier.eligible?(whisper_to_alice)).to eq(false)
    end

    it "never sends a flagged whisper's text to the reports chat" do
      reviewable = PostActionCreator.spam(alice, whisper_to_alice).reviewable
      expect(DiscourseDisteleplus::Reports.excerpt_for(reviewable)).not_to include(secret_a)
      expect(DiscourseDisteleplus::Reports.details_html(reviewable)).not_to include(secret_a)
    end
  end

  describe "converting a public post into a whisper" do
    it "scrubs its public side effects" do
      SiteSetting.mod_whisper_convert_enabled = true
      public_post = reply!(by: author, raw: "public for now https://soon-private.example.com/x")
      expect(TopicLink.where(post_id: public_post.id)).to exist

      sign_in(moderator)
      put "/discourse-mod-categories/post/#{public_post.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [alice.id],
          }
      expect(response.status).to eq(200)

      expect(TopicLink.where(post_id: public_post.id)).not_to exist
      expect(PostSearchData.where(post_id: public_post.id)).not_to exist
      expect(Guardian.new(stranger).can_see_post?(public_post.reload)).to eq(false)
    end
  end
end
