# frozen_string_literal: true

require "rails_helper"

# Dumbcourse's post menu for staff (core's post admin menu, this plugin's pin
# to the bottom and whisper tools, the edit history), selecting posts to move,
# merge, re-own or delete, and whispering, on a keypad phone, each checked
# against what the server ends up with.
RSpec.describe "Dumbcourse post staff actions" do
  fab!(:category) { Fabricate(:category, name: "Flip Phones") }
  fab!(:admin) { Fabricate(:admin, username: "admin_a") }
  fab!(:moderator) { Fabricate(:moderator, username: "mod_m") }
  fab!(:alice) { Fabricate(:user, username: "alice_k", trust_level: TrustLevel[2]) }
  fab!(:bob) { Fabricate(:user, username: "bob_r", trust_level: TrustLevel[2]) }
  fab!(:topic) do
    Fabricate(
      :topic,
      user: alice,
      category: category,
      title: "Looking for a good kosher flip phone",
    )
  end
  fab!(:op) { Fabricate(:post, topic: topic, user: alice, raw: "Which one has the best battery?") }
  fab!(:reply) do
    Fabricate(:post, topic: topic, user: bob, raw: "The Kyocera lasts a few days for me.")
  end
  fab!(:reply2) do
    Fabricate(:post, topic: topic, user: bob, raw: "And the battery swaps out in seconds.")
  end

  before do
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.personal_message_enabled_groups = Group::AUTO_GROUPS[:trust_level_0]
  end

  def press(*keys)
    keys.each do |k|
      page.send_keys(k)
      sleep 0.05
    end
  end

  def phone(&block)
    resize_window(width: 240, height: 320, &block)
  end

  def visit_topic
    visit "/dumb/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".topic-head")
  end

  # A topic seen before shows its saved copy first, and its keys work once
  # the fresh copy is in, which is when the right soft key says Options.
  def wait_until_ready
    expect(page).to have_css("#softkeys .sk-right", text: "Options")
  end

  def open_post_menu(number)
    visit_topic
    wait_until_ready
    find(".post[data-n='#{number}'] .post-when").click
    press(:enter)
    expect(page).to have_css(".sheet-title", text: "##{number}")
  end

  def pick(text)
    find(".sheet-item", text: text, match: :first).click
  end

  def answer(text)
    find("#dlgInput").fill_in(with: text)
    find(".dialog [data-ok]").click
  end

  describe "the post menu" do
    it "turns a post staff-coloured and back" do
      sign_in(moderator)
      phone do
        open_post_menu(2)
        expect(page).to have_css(".sheet-heading", text: /moderation/i)
        pick("Staff colour")
        expect(page).to have_css(".toast", text: "Staff colour on.")
      end
      expect(reply.reload.post_type).to eq(Post.types[:moderator_action])

      phone do
        open_post_menu(2)
        pick("Back to a regular post")
        expect(page).to have_css(".toast", text: "Back to a regular post.")
      end
      expect(reply.reload.post_type).to eq(Post.types[:regular])
    end

    it "adds a staff notice to a post, which everyone then sees" do
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Add post notice…")
        answer("Please keep it on topic.")
        expect(page).to have_css(".toast", text: "Notice saved.")
      end
      expect(reply.reload.custom_fields[Post::NOTICE]["raw"]).to eq("Please keep it on topic.")

      sign_in(alice)
      phone do
        visit_topic
        expect(page).to have_css(".post[data-n='2'] .post-notice", text: "Please keep it on topic.")
      end
    end

    it "locks a post, makes it a wiki and rebuilds it" do
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Lock post")
        expect(page).to have_css(".toast", text: "Post locked.")
      end
      expect(reply.reload.locked_by_id).to eq(moderator.id)

      phone do
        open_post_menu(2)
        pick("Make wiki")
        expect(page).to have_css(".toast", text: "Now a wiki.")
      end
      expect(reply.reload.wiki).to eq(true)

      phone do
        open_post_menu(2)
        pick("Rebuild HTML")
        expect(page).to have_css(".toast", text: "HTML rebuilt.")
      end
    end

    it "unhides a hidden post" do
      reply.update!(hidden: true, hidden_at: Time.zone.now)
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Unhide")
        expect(page).to have_css(".toast", text: "Post unhidden.")
      end
      expect(reply.reload.hidden).to eq(false)
    end

    it "changes a post's owner" do
      sign_in(admin)
      phone do
        open_post_menu(2)
        pick("Change owner…")
        answer("alice_k")
        expect(page).to have_css(".toast", text: "Owner changed to @alice_k.")
      end
      expect(reply.reload.user_id).to eq(alice.id)
    end

    it "grants the author a badge for the post" do
      badge = Fabricate(:badge, name: "Helpful Hint", multiple_grant: false)
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Grant badge…")
        pick("Helpful Hint")
        expect(page).to have_css(".toast", text: "Badge granted.")
      end
      expect(UserBadge.exists?(user_id: bob.id, badge_id: badge.id)).to eq(true)
    end

    it "deletes a deleted post permanently" do
      SiteSetting.can_permanently_delete = true
      PostDestroyer.new(moderator, reply2).destroy
      sign_in(admin)
      phone do
        open_post_menu(3)
        pick("Delete permanently")
        find(".dialog [data-ok]").click
        expect(page).to have_css(".toast", text: "Deleted permanently.")
      end
      expect(Post.with_deleted.find_by(id: reply2.id)).to be_nil
    end

    it "shows a post's edit history and puts back the earlier version" do
      PostRevisor.new(reply).revise!(
        bob,
        { raw: "The Kyocera lasts a whole week for me." },
        force_new_version: true,
      )
      expect(reply.reload.version).to eq(2)
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Edit history")
        expect(page).to have_css(".history-pos", text: "Version 2 of 2")
        expect(page).to have_css(".history-diff", text: /whole week/)
        find("[data-h=revert]").click
        find(".dialog [data-ok]").click
        expect(page).to have_css(".toast", text: "Post reverted.")
      end
      expect(reply.reload.raw).to eq("The Kyocera lasts a few days for me.")
    end

    it "pins a post to the bottom of the topic" do
      SiteSetting.mod_categories_enabled = true
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Pin to the bottom")
        expect(page).to have_css(".toast", text: "Pinned to the bottom.")
      end
      expect(
        topic.reload.custom_fields[DiscourseModCategories::TOPIC_PINNED_POST_FIELD].to_i,
      ).to eq(reply.id)
    end

    it "publishes the topic as a page" do
      SiteSetting.enable_page_publishing = true
      sign_in(admin)
      phone do
        open_post_menu(1)
        pick("Publish as a page…")
        answer("kosher-flip-phones")
        expect(page).to have_css(".toast", text: "Published as a page.")
      end
      expect(PublishedPage.find_by(topic_id: topic.id).slug).to eq("kosher-flip-phones")
    end

    it "hides an edit from everyone but staff" do
      PostRevisor.new(reply).revise!(
        bob,
        { raw: "The Kyocera lasts a whole week for me." },
        force_new_version: true,
      )
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Edit history")
        expect(page).to have_css(".history-pos", text: "Version 2 of 2")
        find("[data-h=visibility]").click
        pick("Staff only (hidden)")
        expect(page).to have_css(".toast", text: "Saved.")
      end
      expect(PostRevision.find_by(post_id: reply.id, number: 2).hidden).to eq(true)
    end

    it "pins a reply at the top of nested replies" do
      SiteSetting.nested_replies_enabled = true
      SiteSetting.nested_replies_default = true
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Pin or unpin in nested replies")
        expect(page).to have_css(".toast", text: "Pinned at the top of nested replies.")
      end
      expect(topic.reload.nested_topic.pinned_post_ids).to include(reply.id)
    end

    it "shows a member none of it" do
      sign_in(alice)
      phone do
        open_post_menu(2)
        expect(page).to have_css(".sheet-item", text: "Copy link")
        expect(page).to have_no_css(".sheet-heading", text: /moderation/i)
        expect(page).to have_no_css(".sheet-item", text: "Staff colour")
      end
    end
  end

  describe "selecting posts" do
    def start_selecting
      visit_topic
      wait_until_ready
      press(:f2)
      pick("Select posts…")
      expect(page).to have_css("html.selecting")
    end

    def select_post(number)
      find(".post[data-n='#{number}'] .post-when").click
      press(:enter)
      expect(page).to have_css(".post.selected[data-n='#{number}']")
    end

    it "moves the chosen replies to a new topic" do
      sign_in(moderator)
      phone do
        start_selecting
        select_post(2)
        select_post(3)
        press(:f2)
        expect(page).to have_css(".sheet-title", text: "2 posts selected")
        pick("Move to a new topic…")
        answer("Kyocera battery life")
        pick("Flip Phones")
        expect(page).to have_css(".toast", text: "Moved to a new topic.")
        expect(page).to have_css(".topic-title", text: "Kyocera battery life")
      end
      moved = Topic.find_by(title: "Kyocera battery life")
      expect(moved.category_id).to eq(category.id)
      expect(moved.posts.where(user_id: bob.id).count).to eq(2)
      expect(reply.reload.topic_id).to eq(moved.id)
    end

    it "merges one author's posts into one" do
      sign_in(moderator)
      phone do
        start_selecting
        select_post(2)
        select_post(3)
        press(:f2)
        pick("Merge into one post")
        find(".dialog [data-ok]").click
        expect(page).to have_css(".toast", text: "Posts merged.")
      end
      merged = topic.posts.where(user_id: bob.id).order(:post_number).last
      expect(merged.raw).to include("lasts a few days", "swaps out in seconds")
    end

    it "deletes the chosen posts" do
      sign_in(moderator)
      phone do
        start_selecting
        select_post(3)
        press(:f2)
        pick("Delete selected")
        find(".dialog [data-ok]").click
        expect(page).to have_css(".toast", text: "Deleted.")
      end
      expect(reply2.reload.deleted_at).to be_present
      expect(reply.reload.deleted_at).to be_nil
    end
  end

  describe "whispers" do
    it "posts a staff-only whisper" do
      SiteSetting.whispers_allowed_groups = Group::AUTO_GROUPS[:staff].to_s
      Group.refresh_automatic_groups!
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Whisper reply (staff only)")
        expect(page).to have_css(".c-notice", text: "only staff can read it")
        find("#cText").fill_in(with: "Keep an eye on this one, please.")
        find("[data-c=send]").click
        expect(page).to have_css(".toast", text: "Whisper posted.")
      end
      whisper = topic.posts.order(:post_number).last
      expect(whisper.raw).to eq("Keep an eye on this one, please.")
      expect(whisper.post_type).to eq(Post.types[:whisper])
    end

    it "whispers to a group" do
      SiteSetting.mod_whisper_enabled = true
      group = Fabricate(:group, name: "testers")
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Whisper to…")
        pick("A group…")
        answer("testers")
        expect(page).to have_css(".c-notice", text: "only testers and staff can read it")
        find("#cText").fill_in(with: "Testers: does this match what you see?")
        find("[data-c=send]").click
        expect(page).to have_css(".toast", text: "Whisper posted.")
      end
      whisper = topic.posts.order(:post_number).last
      expect(
        whisper.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD],
      ).to contain_exactly(group.id)
    end

    it "whispers to the post's author, and makes a whisper public" do
      SiteSetting.mod_whisper_enabled = true
      sign_in(moderator)
      phone do
        open_post_menu(2)
        pick("Whisper to @bob_r")
        find("#cText").fill_in(with: "Could you add which model you have?")
        find("[data-c=send]").click
        expect(page).to have_css(".toast", text: "Whisper posted.")
      end
      whisper = topic.posts.order(:post_number).last
      expect(DiscourseModCategories::Whisper.whisper?(whisper)).to eq(true)
      expect(
        whisper.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD],
      ).to contain_exactly(bob.id)

      phone do
        open_post_menu(whisper.post_number)
        pick("Make public")
        find(".dialog [data-ok]").click
        expect(page).to have_css(".toast", text: "Now a public post.")
      end
      expect(DiscourseModCategories::Whisper.whisper?(whisper.reload)).to eq(false)
    end
  end
end
