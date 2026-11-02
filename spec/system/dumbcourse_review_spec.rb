# frozen_string_literal: true

require "rails_helper"

# Dumbcourse's review queue: the actions the server offers for each item,
# filters, claiming, flag details, reviewer notes and editing a queued post,
# on a keypad phone, each checked against what the server ends up with.
RSpec.describe "Dumbcourse review queue" do
  fab!(:category) { Fabricate(:category, name: "Flip Phones") }
  fab!(:moderator) { Fabricate(:moderator, username: "mod_m") }
  fab!(:alice) { Fabricate(:user, username: "alice_k", trust_level: TrustLevel[2]) }
  fab!(:bob) { Fabricate(:user, username: "bob_r", trust_level: TrustLevel[2]) }
  fab!(:carol) { Fabricate(:user, username: "carol_t", trust_level: TrustLevel[2]) }
  fab!(:topic) do
    Fabricate(
      :topic,
      user: alice,
      category: category,
      title: "Looking for a good kosher flip phone",
    )
  end
  fab!(:op) { Fabricate(:post, topic: topic, user: alice, raw: "Which one has the best battery?") }

  before do
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.mod_categories_enabled = true
  end

  def phone(&block)
    resize_window(width: 240, height: 320, &block)
  end

  def pick(text)
    find(".sheet-item", text: text, match: :first).click
  end

  def answer(text)
    find("#dlgInput").fill_in(with: text)
    find(".dialog [data-ok]").click
  end

  # A reply that waits for approval, the way this plugin queues one.
  def queued_reply
    topic.custom_fields[DiscourseModCategories::TOPIC_REQUIRE_REPLY_APPROVAL_FIELD] = true
    topic.save_custom_fields(true)
    result =
      NewPostManager.new(
        bob,
        raw: "The Kyocera lasts a few days for me.",
        topic_id: topic.id,
      ).perform
    expect(result.action).to eq(:enqueued)
    result.reviewable
  end

  def open_item
    visit "/dumb/review"
    find(".row.review", match: :first).click
    expect(page).to have_css(".sheet-heading", text: /details/i)
  end

  it "approves a queued reply" do
    reviewable = queued_reply
    sign_in(moderator)
    phone do
      open_item
      pick("Approve")
      expect(page).to have_css(".toast", text: "Done.")
    end
    expect(reviewable.reload.status).to eq("approved")
    expect(topic.posts.where(user_id: bob.id).count).to eq(1)
  end

  it "edits a queued reply before approving it" do
    reviewable = queued_reply
    sign_in(moderator)
    phone do
      open_item
      pick("Edit before approving…")
      pick("The post")
      answer("The Kyocera DuraXV lasts a few days for me.")
      expect(page).to have_css(".toast", text: "Saved.")
    end
    expect(reviewable.reload.payload["raw"]).to eq("The Kyocera DuraXV lasts a few days for me.")
  end

  it "keeps each action's name readable on a narrow screen" do
    post = Fabricate(:post, topic: topic, user: bob, raw: "Buy cheap phones at my site.")
    PostActionCreator.spam(carol, post)
    sign_in(moderator)
    phone do
      open_item
      expect(page).to have_css(".sheet-item", text: "Hide post")
      narrowest = page.evaluate_script(<<~JS)
          Math.min.apply(null, Array.prototype.map.call(
            document.querySelectorAll(".layer.open .sheet-item .sheet-label"),
            function (el) { return el.getBoundingClientRect().width; }
          ))
        JS
      expect(narrowest).to be > 80
    end
  end

  it "shows who flagged a post and why, and takes a note" do
    post = Fabricate(:post, topic: topic, user: bob, raw: "Buy cheap phones at my site.")
    reviewable = PostActionCreator.spam(carol, post).reviewable
    sign_in(moderator)
    phone do
      open_item
      pick("1 flag")
      expect(page).to have_css(".sheet-item", text: "@carol_t: Spam")
      visit "/dumb/review"
      find(".row.review", match: :first).click
      pick("Add a note…")
      answer("Same link as last week.")
      expect(page).to have_css(".toast", text: "Note added.")
    end
    expect(ReviewableNote.where(reviewable_id: reviewable.id).pluck(:content)).to eq(
      ["Same link as last week."],
    )
  end

  it "claims an item and lets it go" do
    SiteSetting.reviewable_claiming = "optional"
    queued_reply
    sign_in(moderator)
    phone do
      open_item
      pick("Claim")
      expect(page).to have_css(".toast", text: "Claimed.")
    end
    expect(ReviewableClaimedTopic.exists?(topic_id: topic.id, user_id: moderator.id)).to eq(true)

    phone do
      open_item
      pick("Unclaim")
      expect(page).to have_css(".toast", text: "Unclaimed.")
    end
    expect(ReviewableClaimedTopic.exists?(topic_id: topic.id)).to eq(false)
  end

  it "suspends the author from a flag, and deletes the post with it" do
    post = Fabricate(:post, topic: topic, user: bob, raw: "Buy cheap phones at my site.")
    PostActionCreator.spam(carol, post)
    sign_in(moderator)
    phone do
      open_item
      pick("Suspend user")
      pick("1 week")
      answer("Spam")
      answer("")
      pick("Delete the post")
      expect(page).to have_css(".toast", text: "Done.")
    end
    expect(bob.reload.suspended?).to eq(true)
    expect(post.reload.deleted_at).to be_present
  end

  it "filters by who flagged, and shows an item's history" do
    first = Fabricate(:post, topic: topic, user: bob, raw: "Buy cheap phones at my site.")
    second = Fabricate(:post, topic: topic, user: bob, raw: "Cheap phones, my site again.")
    PostActionCreator.spam(carol, first)
    PostActionCreator.off_topic(alice, second)
    sign_in(moderator)
    phone do
      visit "/dumb/review?flagged_by=carol_t"
      expect(page).to have_css(".row.review", count: 1)
      expect(page).to have_css(".row.review", text: "Spam")
      find(".row.review").click
      pick("History")
      expect(page).to have_css(".sheet-item", text: "Created")
    end
  end

  it "lets an admin set how much a flag reason weighs" do
    sign_in(Fabricate(:admin))
    phone do
      visit "/dumb/review"
      find("[data-act=review-filter]").click
      pick("Priorities of flag reasons…")
      pick("Spam")
      pick("High")
      expect(page).to have_css(".toast", text: "Priority saved.")
    end
    expect(PostActionType.find_by(name_key: "spam").reviewable_priority).to eq(
      Reviewable.priorities[:high],
    )
  end

  it "filters by status" do
    reviewable = queued_reply
    reviewable.perform(moderator, :approve_post)
    sign_in(moderator)
    phone do
      visit "/dumb/review"
      expect(page).to have_css(".state-empty", text: "Nothing to review.")
      find("[data-act=review-filter]").click
      pick("Status")
      pick("Approved")
      expect(page).to have_current_path(%r{/dumb/review\?status=approved})
      expect(page).to have_css(".row.review", text: "Waiting for approval")
      expect(page).to have_css(".row.review", text: "Approved")
    end
  end
end
