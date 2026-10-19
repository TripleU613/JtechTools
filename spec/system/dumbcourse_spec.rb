# frozen_string_literal: true

require "rails_helper"
require "rotp"

# Dumbcourse end to end, driven the way a flip phone drives it: arrow keys,
# OK (Enter), the soft keys (F1/F2 stand in for SoftLeft/SoftRight) and the
# keypad digits, on a 240×320 screen. Set JTECH_SCREENSHOT_GALLERY=1 to also
# save screenshots (tmp/capybara/dumbcourse_*.png).
RSpec.describe "Dumbcourse" do
  fab!(:category) { Fabricate(:category, name: "Flip Phones", color: "E45735") }
  fab!(:alice) do
    Fabricate(
      :user,
      username: "alice_k",
      name: "Alice Klein",
      trust_level: TrustLevel[2],
      password: "supersecretpassword1",
      active: true,
    )
  end
  fab!(:bob) do
    Fabricate(
      :user,
      username: "bob_m",
      name: "Bob Mizrachi",
      trust_level: TrustLevel[2],
      password: "anothersecretpass22",
      active: true,
    )
  end
  fab!(:topic) do
    Fabricate(
      :topic,
      user: alice,
      category: category,
      title: "Looking for a good kosher flip phone",
    )
  end
  fab!(:op) do
    Fabricate(
      :post,
      topic: topic,
      user: alice,
      raw: "Which one has the best battery? I tried the **Nokia 2780**.",
    )
  end
  fab!(:reply) do
    Fabricate(
      :post,
      topic: topic,
      user: bob,
      raw: "The Kyocera DuraXV lasts days. See https://example.com/duraxv for specs.",
    )
  end

  before do
    # Signing in also needs a confirmed email.
    alice.activate
    bob.activate
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.reqpm_enabled = true
    SiteSetting.hide_new_user_profiles = false
  end

  def shot(name)
    return unless ENV["JTECH_SCREENSHOT_GALLERY"]
    page.save_screenshot("dumbcourse_#{name}.png")
  end

  def focused_key
    page.evaluate_script(
      "document.activeElement && document.activeElement.getAttribute('data-key')",
    )
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

  describe "signing in" do
    it "with a password, typed on the keypad" do
      phone do
        visit "/dumb/"
        expect(page).to have_css("#login")
        shot("01_sign_in")
        find("#login").send_keys("alice_k")
        press(:down)
        page.send_keys("supersecretpassword1", :enter)
        expect(page).to have_css(".row.topic", text: "Looking for a good kosher flip phone")
        expect(page).to have_css("#tbTitle", text: SiteSetting.title)
      end
    end

    it "asks for the two-factor code when the account has one" do
      totp = Fabricate(:user_second_factor_totp, user: alice)
      phone do
        visit "/dumb/login"
        find("#login").fill_in(with: "alice_k")
        find("#password").fill_in(with: "supersecretpassword1")
        find("[data-login-btn]").click
        expect(page).to have_css("#tfaCode")
        shot("02_two_factor")
        find("#tfaCode").fill_in(with: ROTP::TOTP.new(totp.data).now)
        find("[data-login-btn]").click
        expect(page).to have_css(".row.topic")
      end
    end

    it "says so when the password is wrong" do
      phone do
        visit "/dumb/login"
        find("#login").fill_in(with: "alice_k")
        find("#password").fill_in(with: "wrong password here")
        find("[data-login-btn]").click
        expect(page).to have_css("#authError", text: /incorrect/i)
      end
    end

    # The phone and the approving device run in one browser here (a second
    # browser can't be launched in every CI sandbox); the request spec
    # covers the two-session flow.
    it "by approving the phone from another device — the phone's side" do
      phone do
        visit "/dumb/login"
        click_link "Sign in with another device"
        expect(page).to have_css(".pair-code")
        shot("03_pair_code")
        code = find(".pair-code").text.delete("-")
        DiscourseDumbcourse::Pairing.approve!(code, alice)
        expect(page).to have_css(".row.topic", wait: 15)
        expect(page).to have_no_css("#login")
      end
    end

    it "by approving the phone from another device — the approver's side" do
      code, _secret =
        DiscourseDumbcourse::Pairing.start!(user_agent: "KAIOS/3.1 Firefox/84.0", ip: "10.0.0.8")
      sign_in(alice)
      visit "/dumb/link"
      find("#pairCode").fill_in(with: code.downcase.insert(4, "-"))
      find("[data-link] button[type=submit]").click
      expect(page).to have_css(".dialog-text", text: /Sign in this device as @alice_k/)
      expect(page).to have_css(".dialog-text", text: /KaiOS phone/)
      find(".dialog [data-ok]").click
      expect(page).to have_css(".dialog-title", text: "Approved")
      expect(DiscourseDumbcourse::Pairing.find(code)[:status]).to eq("approved")
    end

    it "from an emailed sign-in link" do
      token = Fabricate(:email_token, user: alice, scope: EmailToken.scopes[:email_login])
      phone do
        visit "/dumb/email-login/#{token.token}"
        expect(page).to have_css("[data-confirm] button[type=submit]")
        find("[data-confirm] button[type=submit]").click
        expect(page).to have_css(".row.topic")
      end
    end

    it "after setting a new password from an emailed reset link" do
      token = Fabricate(:email_token, user: alice, scope: EmailToken.scopes[:password_reset])
      phone do
        visit "/dumb/password-reset/#{token.token}"
        find("#newPass").fill_in(with: "a brand new long password")
        find("[data-reset] button[type=submit]").click
        expect(page).to have_css(".row.topic")
      end
      expect(alice.reload.confirm_password?("a brand new long password")).to eq(true)
    end
  end

  # With Discourse's Unified New on, /new.json also lists topics with unread
  # replies, and Dumbcourse's New showed what its Unread tab shows
  describe "New and Unread with Discourse's Unified New on" do
    fab!(:fresh) do
      Fabricate(:topic, user: alice, category: category, title: "Is the Qin F25 worth it?")
    end

    before do
      SiteSetting.enable_unified_new = true
      bob.user_option.update!(new_topic_duration_minutes: User::NewTopicDuration::ALWAYS)
      Fabricate(:post, topic: fresh, user: alice, raw: "Thinking of getting one for my son.")
      # bob read the first post of the flip phone topic and tracks it
      topic.update!(highest_post_number: 2, posts_count: 2)
      TopicUser.change(
        bob.id,
        topic.id,
        last_read_post_number: 1,
        notification_level: TopicUser.notification_levels[:tracking],
      )
      sign_in(bob)
    end

    it "lists only new topics under New, and topics with unread replies under Unread" do
      phone do
        visit "/dumb/new"
        expect(page).to have_css(".row.topic", text: fresh.title)
        expect(page).to have_no_css(".row.topic", text: topic.title)

        visit "/dumb/unread"
        expect(page).to have_css(".row.topic", text: topic.title)
        expect(page).to have_no_css(".row.topic", text: fresh.title)
      end
    end

    it "dismisses the new topics from New, and leaves the unread ones" do
      phone do
        visit "/dumb/new"
        expect(page).to have_css(".row.topic", text: fresh.title)
        press("9")
        find(".sheet-item", text: "Dismiss all new").click
        find(".dialog [data-ok]").click
        expect(page).to have_no_css(".row.topic", text: fresh.title)
      end
      expect(DismissedTopicUser.exists?(user: bob, topic: fresh)).to eq(true)
      expect(TopicUser.get(topic, bob).last_read_post_number).to eq(1)
    end
  end

  describe "reading and writing with the D-pad" do
    before { sign_in(bob) }

    it "opens a topic, moves post to post, and likes from the post's actions" do
      phone do
        visit "/dumb/"
        expect(page).to have_css(".row.topic")
        expect(focused_key).to eq("t#{topic.id}")
        shot("04_latest")
        press(:enter)
        expect(page).to have_css(".post[data-n='1']")
        press(:right)
        expect(focused_key).to eq("p1")
        press(:enter)
        expect(page).to have_css(".sheet-title", text: "#1")
        shot("05_post_sheet")
        find(".sheet-item", text: "Like").click
        expect(page).to have_css(".toast", text: "Liked")
        expect(
          PostAction.exists?(post_id: op.id, user_id: bob.id) ||
            DiscourseReactions::ReactionUser.exists?(post_id: op.id, user_id: bob.id),
        ).to eq(true)
      end
    end

    # On a computer: the selected post had a ring outside its border as well
    # as the bar, a glaring white rim on the JTech palette, and the top bar's
    # buttons sat at the window's edges, far from the 44rem column under them
    it "marks the selected post calmly and keeps the top bar to the column on a wide screen" do
      resize_window(width: 1400, height: 900) do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        expect(page).to have_css(".post[data-n='1']")
        ring, bar_left, column_left = page.evaluate_script(<<~JS)
          (() => {
            const post = document.querySelector(".post[data-n='1']");
            post.focus();
            return [
              getComputedStyle(post).boxShadow,
              document.querySelector("#topbar > *").getBoundingClientRect().left,
              document.querySelector("#app").getBoundingClientRect().left,
            ];
          })()
        JS
        # one shadow, the inset bar: no ring outside the border
        expect(ring.scan(/rgba?\(/).size).to eq(1)
        expect(ring).to include("inset")
        expect(bar_left).to be_within(8).of(column_left)
      end
    end

    it "lists a post's links in its action sheet" do
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        find(".post[data-n='2']").click
        press(:enter)
        expect(page).to have_css(".sheet-heading", text: /1 link in this post/i)
        expect(page).to have_css(".sheet-item[href='https://example.com/duraxv']")
      end
    end

    # A small PNG as a data: URI (the page's CSP allows data: pictures), so the
    # viewer loads real pictures without upload files.
    def png_uri(width, height, rgb)
      chunk = ->(type, data) do
        [data.bytesize].pack("N") + type.b + data + [Zlib.crc32(type.b + data)].pack("N")
      end
      rows = ("\x00".b + rgb.pack("C3") * width) * height
      png =
        "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNC5")) +
          chunk.call("IDAT", Zlib::Deflate.deflate(rows)) + chunk.call("IEND", "".b)
      "data:image/png;base64,#{Base64.strict_encode64(png)}"
    end

    # Post #3, with this cooked HTML as-is (what Discourse makes of an upload).
    def picture_post(cooked)
      post = Fabricate(:post, topic: topic, user: bob, raw: "Pictures of my phone, and a link.")
      post.update_columns(cooked: cooked)
    end

    # The viewer's position, as it reads: "‹ 2 / 2" is the counter with only
    # the ‹ (previous) arrow showing.
    def expect_position(text)
      expect(page).to have_css(".picture-layer .pv-count", exact_text: text.delete("‹›").strip)
      if text.start_with?("‹")
        expect(page).to have_css(".picture-layer .pv-prev")
      else
        expect(page).to have_no_css(".picture-layer .pv-prev")
      end
      if text.end_with?("›")
        expect(page).to have_css(".picture-layer .pv-next")
      else
        expect(page).to have_no_css(".picture-layer .pv-next")
      end
    end

    def open_post_menu(number)
      visit "/dumb/t/#{topic.slug}/#{topic.id}"
      # Its timestamp, not its middle, which may be a link or a picture.
      find(".post[data-n='#{number}'] .post-when").click
      press(:enter)
    end

    it "shows a post's picture full size: zooms, saves, and Back returns to the post" do
      wide = png_uri(600, 400, [200, 40, 40])
      picture_post(<<~HTML)
        <p>Specs at <a href="https://example.com/specs">example.com</a>.</p>
        <div class="lightbox-wrapper"><a class="lightbox" href="#{wide}" data-download-href="/uploads/default/0123abcd" title="My phone"><img src="#{wide}" alt="My phone" width="300" height="200"></a></div>
      HTML
      phone do
        open_post_menu(3)
        # First in the menu, and focused: OK, OK opens it.
        expect(page).to have_css(".sheet-item:focus", text: "View picture")
        expect(page).to have_css(".sheet-heading", text: /1 link in this post/i)
        expect(page).to have_no_css(".sheet-heading", text: /picture/i)
        find(".sheet-item", text: "View picture").click

        expect(page).to have_css(".picture-layer .pv-stage[data-zoom='1']:focus")
        expect(page).to have_css(".picture-layer .pv-name", text: "My phone")
        expect(page).to have_no_css(".picture-layer .pv-count", text: /\S/)
        expect(page).to have_no_css(".picture-layer .pv-pos")
        # The labels appear once the picture has loaded.
        expect(page).to have_css("#softkeys .sk-left", text: /close/i)
        expect(page).to have_css("#softkeys .sk-center", text: /zoom/i)
        expect(page).to have_css("#softkeys .sk-right", text: /save/i)
        expect(page).to have_css(
          ".pv-save[href='/uploads/default/0123abcd?dl=1'][download]",
          visible: :all,
        )

        press(:enter)
        expect(page).to have_css(".pv-stage[data-zoom='2']")
        press(:enter)
        expect(page).to have_css(".pv-stage[data-zoom='3']")
        expect(page).to have_css("#softkeys .sk-center", text: /fit/i)
        press(:enter)
        expect(page).to have_css(".pv-stage[data-zoom='1']")

        press(:backspace)
        expect(page).to have_no_css(".picture-layer")
        expect(focused_key).to eq("p3")
      end
    end

    it "pages through a post's pictures from a gallery" do
      wide = png_uri(600, 400, [200, 40, 40])
      tall = png_uri(300, 500, [40, 80, 200])
      picture_post(%(<p><img src="#{wide}" alt="image"> <img src="#{tall}" alt="image"></p>))
      phone do
        open_post_menu(3)
        find(".sheet-item", text: "View pictures (2)").click

        expect(page).to have_css(".pictures-layer .pg-cell", count: 2)
        expect(page).to have_css(".pictures-layer .pg-cell[data-i='0']:focus")
        expect(page).to have_css("#softkeys .sk-center", text: /view/i)
        press(:right, :enter)

        expect(page).to have_css(".picture-layer .pv-count", text: "2 / 2")
        expect(page).to have_css("#softkeys .sk-center", text: /zoom/i)
        # Not forum uploads: nothing to download.
        expect(page).to have_no_css("#softkeys .sk-right", text: /\S/)
        expect_position("‹ 2 / 2")
        press(:left)
        expect_position("1 / 2 ›")

        # Zoomed, the D-pad moves the picture; 6 still goes to the next one.
        press(:enter)
        expect(page).to have_css(".pv-stage[data-zoom='2']")
        press("6")
        expect_position("‹ 2 / 2")
        expect(page).to have_css(".pv-stage[data-zoom='1']")
        press("4")
        expect_position("1 / 2 ›")

        press(:backspace)
        expect(page).to have_no_css(".picture-layer")
        expect(page).to have_css(".pictures-layer .pg-cell[data-i='1']:focus")
        press(:backspace)
        expect(page).to have_no_css(".pictures-layer")
      end
    end

    it "opens a picture tapped in a post in the viewer, and taps through them" do
      wide = png_uri(600, 400, [200, 40, 40])
      tall = png_uri(300, 500, [40, 80, 200])
      picture_post(<<~HTML)
        <div class="lightbox-wrapper"><a class="lightbox" href="#{wide}" data-download-href="/uploads/default/0123abcd" title="My phone"><img src="#{wide}" alt="My phone" width="300" height="200"></a></div>
        <p><img src="#{tall}" alt="image"></p>
      HTML
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        topic_path = page.current_path

        # The second picture: the viewer opens on it, not the bare file.
        find(".post[data-n='3'] img[data-pic='1']").click
        expect(page).to have_css(".picture-layer .pv-stage[data-zoom='1']:focus")
        expect_position("‹ 2 / 2")

        # The arrows beside the counter are tapped to go through them.
        find(".picture-layer .pv-prev").click
        expect_position("1 / 2 ›")
        expect(page).to have_css(".picture-layer .pv-name", text: "My phone")
        expect(page).to have_css(".picture-layer .pv-stage:focus")
        find(".picture-layer .pv-next").click
        expect_position("‹ 2 / 2")

        # Tapping the picture zooms; the soft-key bar's Close closes.
        find(".picture-layer .pv-stage").click
        expect(page).to have_css(".pv-stage[data-zoom='2']")
        find("#softkeys .sk-left").click
        expect(page).to have_no_css(".picture-layer")

        # The first picture is inside its lightbox link: the viewer, not the link.
        find(".post[data-n='3'] a.lightbox").click
        expect_position("1 / 2 ›")
        expect(page).to have_css("#softkeys .sk-right", text: /save/i)
        expect(page.windows.size).to eq(1)
        expect(page).to have_current_path(topic_path)
      end
    end

    it "replies with the keypad and the soft keys" do
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        expect(page).to have_css(".post[data-n='2']")
        find(".post[data-n='2']").click
        press("3")
        expect(page).to have_css("#cText")
        expect(page).to have_css(".c-context", text: "@bob_m")
        find("#cText").send_keys("Thanks, that is really useful to know!")
        shot("06_composer")
        press(:f2)
        expect(page).to have_css(".toast", text: "Reply posted")
        expect(page).to have_css(".post", text: "Thanks, that is really useful to know!")
      end
      expect(topic.posts.last.raw).to eq("Thanks, that is really useful to know!")
      expect(topic.posts.last.reply_to_post_number).to eq(2)
    end

    it "asks before closing a composer with writing, and keeps the draft" do
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        find("[data-act=reply-topic]").click
        find("#cText").send_keys("Half a thought")
        sleep 0.8
        press(:escape)
        expect(page).to have_css(".dialog-text", text: "Your draft stays on this phone")
        find(".layer [data-cancel]").click
        expect(page).to have_no_css(".dialog-text")
        expect(page).to have_field("cText", with: "Half a thought")
        press(:escape)
        find(".layer [data-ok]", text: "Close").click
        expect(page).to have_no_css("#cText")
        visit "/dumb/drafts"
        expect(page).to have_css(".row", text: "Reply: Looking for a good kosher flip phone")
        find(".row", text: "Reply:").click
        find(".sheet-item", text: "Continue writing").click
        expect(page).to have_field("cText", with: "Half a thought")
      end
    end

    it "closes an empty composer without asking" do
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        find("[data-act=reply-topic]").click
        expect(page).to have_css("#cText")
        press(:escape)
        expect(page).to have_no_css("#cText")
        expect(page).to have_no_css(".dialog-text")
      end
    end

    it "stays in the forum on Back after discarding a draft" do
      phone do
        visit "/dumb/"
        find(".row.topic", text: "Looking for a good kosher flip phone").click
        expect(page).to have_css(".post[data-n='1']")
        press(:f2)
        find(".sheet-item", text: "Reply to topic").click
        find("#cText").send_keys("Never mind")
        find("[data-c=discard]").click
        find(".layer [data-ok]", text: "Discard").click
        expect(page).to have_no_css("#cText")
        expect(page).to have_css(".post[data-n='1']")
        page.go_back
        expect(page).to have_css(".row.topic", text: "Looking for a good kosher flip phone")
        expect(page).to have_current_path("/dumb/")
      end
    end

    it "bookmarks a post" do
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        find(".post[data-n='1']").click
        press(:enter)
        find(".sheet-item", text: "Bookmark").click
        expect(page).to have_css(".toast", text: "Bookmarked")
        expect(
          Bookmark.exists?(user_id: bob.id, bookmarkable_id: op.id, bookmarkable_type: "Post"),
        ).to eq(true)
        visit "/dumb/bookmarks"
        expect(page).to have_css(".row", text: "Looking for a good kosher flip phone")
      end
    end

    it "starts a new topic in a category" do
      phone do
        visit "/dumb/"
        press("3")
        expect(page).to have_css("#cTitle")
        find("#cTitle").fill_in(with: "Best case for the TCL Flip Pro")
        find("#cCat").select("Flip Phones")
        find("#cText").fill_in(with: "Mine keeps getting scratched. Any recommendations?")
        find("[data-c=send]").click
        expect(page).to have_css(".topic-title", text: "Best case for the TCL Flip Pro")
      end
      expect(Topic.last.category).to eq(category)
    end

    it "shows notifications and marks them read when opened" do
      notification =
        Notification.create!(
          notification_type: Notification.types[:mentioned],
          user_id: bob.id,
          topic_id: topic.id,
          post_number: 1,
          data: { topic_title: topic.title, display_username: "alice_k" }.to_json,
        )
      phone do
        visit "/dumb/"
        expect(page).to have_css("#tbBadge", text: "1")
        visit "/dumb/notifications"
        expect(page).to have_css(".row.notif.unread", text: "alice_k mentioned you in")
        shot("07_notifications")
        find(".row.notif").click
        expect(page).to have_css(".post[data-n='1']")
      end
      expect(notification.reload.read).to eq(true)
    end

    it "opens the menu with the left soft key" do
      phone do
        visit "/dumb/"
        press(:f1)
        expect(page).to have_css(".layer-drawer .menu-item", text: "Notifications")
        shot("08_menu")
        press(:escape)
        expect(page).to have_no_css(".layer-drawer")
      end
    end

    # On a computer the menu opened at the window's far edge, away from the
    # column it belongs to
    it "opens the menu at the content's column on a wide screen" do
      resize_window(width: 1400, height: 900) do
        visit "/dumb/"
        expect(page).to have_css(".row.topic")
        find("#tbMenu").click
        expect(page).to have_css(".layer-drawer .menu-item", text: "Notifications")
        drawer_left, column_left = page.evaluate_script(<<~JS)
          [
            document.querySelector(".layer-drawer .layer-panel").getBoundingClientRect().left,
            document.querySelector("#app").getBoundingClientRect().left,
          ]
        JS
        expect(drawer_left).to be_within(2).of(column_left)
      end
    end

    it "repeats the screen's soft-key actions in the menu" do
      phone do
        visit "/dumb/"
        expect(page).to have_css("#softkeys .sk-right", text: "Options")
        press("*")
        find(".layer-drawer .menu-item[data-menu=screen]", text: "Options").click
        expect(page).to have_css(".sheet-item", text: "New topic")
      end
    end

    it "learns a soft key the phone sends under another name" do
      phone do
        visit "/dumb/phone-keys"
        find(".row[data-which=softleft]").click
        expect(page).to have_css("#pk-softleft", text: "Press it now")
        press(:f9)
        expect(page).to have_css("#pk-softleft", text: "F9")
        expect(page).to have_css("#pkLast", text: "Left soft key")
        visit "/dumb/"
        press(:f9)
        expect(page).to have_css(".layer-drawer .menu-item", text: "Notifications")
      end
    end

    it "takes soft keys that some Android browsers only name on keyup" do
      phone do
        visit "/dumb/"
        expect(page).to have_css("#softkeys .sk-left")
        page.execute_script(<<~JS)
          function fire(type, key, keyCode) {
            var e = new KeyboardEvent(type, { key: key, bubbles: true, cancelable: true });
            Object.defineProperty(e, "keyCode", { get: function () { return keyCode; } });
            document.body.dispatchEvent(e);
          }
          fire("keydown", "Unidentified", 229);
          fire("keyup", "SoftLeft", 0);
        JS
        expect(page).to have_css(".layer-drawer .menu-item", text: "Notifications")
      end
    end

    it "remembers the theme and text size" do
      phone do
        visit "/dumb/preferences"
        find(".row[data-pref=theme]").click
        find(".sheet-item", text: "Light").click
        expect(page).to have_css("html.light")
        find(".row[data-pref=textSize]").click
        find(".sheet-item", text: "125%").click
        visit "/dumb/"
        expect(page).to have_css("html.light")
        expect(page.evaluate_script("document.documentElement.style.fontSize")).to eq("18.75px")
      end
    end

    it "keeps focus when fresh data repaints a screen shown from cache" do
      phone do
        visit "/dumb/u/#{bob.username}"
        expect(page).to have_css(".profile-actions .btn:focus", text: "Preferences")
        # The next visit paints the cached profile, then the changed one.
        bob.update!(name: "Bob Renamed")
        visit "/dumb/u/#{bob.username}"
        expect(page).to have_css(".profile h1", text: "Bob Renamed")
        expect(page).to have_css(".profile-actions .btn:focus", text: "Preferences")
      end
    end

    it "keeps focus on the setting just changed" do
      phone do
        visit "/dumb/preferences"
        find(".row[data-pref=softkeys]").click
        find(".sheet-item", text: "Always").click
        # Before: the screen re-ran from scratch and focus went back to Theme.
        expect(page).to have_css(".row[data-pref=softkeys]:focus", text: "Always")
      end
    end
  end

  # On a touch phone a post's footer rolls its reactions out beside the
  # like, as many as the forum has turned on; the keypad keeps React… in the
  # post's menu.
  describe "reactions on a touch screen" do
    before do
      SiteSetting.discourse_reactions_enabled_reactions =
        "+1|laughing|open_mouth|clap|confetti_ball|hugs|trophy|tada|fire|pray|thinking|100|eyes|rocket"
      sign_in(bob)
    end

    let(:foot) { ".post[data-n='1'] .post-foot" }

    it "rolls them out in the footer, in a row that scrolls, and picks one" do
      resize_window(width: 360, height: 740) do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        expect(page).to have_css("#{foot} .rx-open")
        find("#{foot} .rx-open").click
        # the heart is the like beside it, not in the row
        expect(page).to have_css("#{foot}.rolled .rx-row .rx-pick", count: 14)
        # the like and Reply stay, the rest step aside
        expect(page).to have_css("#{foot} .pa.like")
        expect(page).to have_css("#{foot} [data-act='reply-post']")
        expect(page).to have_no_css("#{foot} [data-act='post-menu']")
        scrolls =
          page.evaluate_script(
            "(() => { const r = document.querySelector(\"#{foot} .rx-row\"); return r.scrollWidth > r.clientWidth; })()",
          )
        expect(scrolls).to eq(true)
        shot("reactions_row")

        # a second tap shuts it
        find("#{foot} .rx-open").click
        expect(page).to have_no_css("#{foot} .rx-row")
        expect(page).to have_css("#{foot} [data-act='post-menu']")

        find("#{foot} .rx-open").click
        find("#{foot} .rx-pick[data-reaction='fire']").click
        try_until_success do
          expect(
            DiscourseReactions::ReactionUser.joins(:reaction).where(
              user: bob,
              post: op,
              reaction: {
                reaction_value: "fire",
              },
            ),
          ).to exist
        end
        expect(page).to have_css(".post[data-n='1'] .rx.mine[data-reaction='fire']")
        expect(page).to have_no_css("#{foot} .rx-row")
      end
    end

    it "has no row on your own posts" do
      resize_window(width: 360, height: 740) do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        expect(page).to have_css(".post[data-n='2'] .post-foot")
        expect(page).to have_no_css(".post[data-n='2'] .rx-open")
      end
    end
  end

  describe "REQ-PM" do
    it "asks someone for their contact details from their profile" do
      sign_in(bob)
      phone do
        visit "/dumb/u/alice_k"
        find("a", text: "Contact details").click
        expect(page).to have_css("[data-act=ask]")
        find("[data-act=ask]").click
        expect(page).to have_css(".toast", text: "Request sent.")
        expect(page).to have_css(".notice", text: "Requested")
      end
      expect(DiscourseReqpm::Request.where(requester_id: bob.id, target_id: alice.id)).to exist
    end
  end

  describe "moderation" do
    fab!(:moderator) { Fabricate(:moderator, username: "mod_m") }

    it "closes a topic from the topic menu" do
      sign_in(moderator)
      phone do
        visit "/dumb/t/#{topic.slug}/#{topic.id}"
        expect(page).to have_css(".topic-head")
        press(:f2)
        find(".sheet-item", text: "Close topic").click
        expect(page).to have_css(".toast", text: "Done")
      end
      expect(topic.reload.closed).to eq(true)
    end
  end

  it "signs out and forgets the account's drafts" do
    sign_in(bob)
    phone do
      visit "/dumb/t/#{topic.slug}/#{topic.id}"
      find("[data-act=reply-topic]").click
      find("#cText").send_keys("Private draft")
      sleep 0.8
      press(:escape)
      visit "/dumb/logout"
      find(".dialog [data-ok]").click
      expect(page).to have_css("#login")
      stored = page.evaluate_script("JSON.stringify(Object.keys(localStorage))")
      expect(stored).not_to include("dc:user:")
    end
  end
end
