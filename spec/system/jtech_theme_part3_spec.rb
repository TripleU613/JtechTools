# frozen_string_literal: true

require "rails_helper"

# The JTech theme in a browser, part 3 of 4. Setup, and what the
# suite covers: spec/support/jtech_theme_context.rb.
RSpec.describe "JTech theme" do
  include_context "jtech theme"

  # Nine or more buttons (staff on jtechforums.org also get View translation
  # and Solution) are wider than a 320px phone's column (a Qin F21). The row
  # sits against the right edge, so the first ones hung off the screen's left
  # edge, where nothing scrolls to them: they wrap now. (The row's scroll
  # width doesn't count what hangs off the left, so the spec above can't see
  # it.)
  it "keeps every one of a long row of post buttons on a 320px phone", mobile: true do
    SiteSetting.post_menu = "read|like|copyLink|share|flag|edit|bookmark|delete|admin|reply"
    SiteSetting.post_menu_hidden_items = ""
    sign_in(admin)
    resize_window(width: 320) do
      visit(topic.relative_url)
      expect(page).to have_css("#post_1 nav.post-controls .actions .post-action-menu__share")
      edges = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("nav.post-controls .actions > *")]
          .map((button) => button.getBoundingClientRect())
          .filter((box) => box.width)
          .flatMap((box) => [Math.round(box.left), Math.round(box.right)])
      JS
      expect(edges.min).to be >= 0
      expect(edges.max).to be <= 320
      expect_no_theme_errors
    end
  end

  it "doesn't offer Quick look to visitors, so it can't get round a login gate" do
    visit("/latest")
    expect(page).to have_css(".jt-card")
    expect(page).to have_no_css(".jt-card__peek")
  end

  # Core's bookmarks are a bare table, the activity stream posts stacked with
  # hairlines, the inbox a plain topic list. The theme: a card, cards, cards.
  it "puts a member's bookmarks, activity and inbox on cards" do
    Fabricate(:bookmark, user: member, bookmarkable: first_post, name: "Read again")
    Fabricate(:topic_user, user: member, topic: topic) # the bookmarks query joins it
    # the activity stream reads user actions, which specs don't log by default
    UserActionManager.enable
    UserActionManager.topic_created(topic)
    UserActionManager.post_created(first_post)
    pm = Fabricate(:private_message_topic, user: admin, recipient: member)
    Fabricate(:post, topic: pm, user: admin, raw: "A note for the inbox layout.")
    sign_in(member)
    visit("/latest") # the theme compiles on the first request; don't time that
    expect(page).to have_css(".jt-card")

    visit("/u/#{member.username}/activity/bookmarks")
    expect(page).to have_css(".bookmark-list .bookmark-list-item", text: "Read again", wait: 15)
    bookmarks_border = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".topic-list.bookmark-list")).borderTopWidth
    JS
    expect(bookmarks_border).to eq("1px")

    visit("/u/#{member.username}/activity")
    expect(page).to have_css(".user-stream .post-list-item", text: "blocks the browser")
    stream_border = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".user-stream .post-list-item")).borderTopWidth
    JS
    expect(stream_border).to eq("1px")

    visit("/u/#{member.username}/messages")
    expect(page).to have_css(".topic-list.jt-cards .jt-card", text: pm.title)
    expect_no_theme_errors
  end

  # A message has no category (core hides it in message lists) and often no
  # tags or pills, but its card kept the empty line over the title, which took
  # the card's gap: 8px more above the title than under the footer
  it "leaves the empty line out of a message's card" do
    pm = Fabricate(:private_message_topic, user: admin, recipient: member)
    Fabricate(:post, topic: pm, user: admin, raw: "Which filter did you end up using?")
    sign_in(member)
    visit("/u/#{member.username}/messages")
    expect(page).to have_css(".topic-list.jt-cards td.jt-card", text: pm.title)
    card = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".topic-list.jt-cards td.jt-card");
        const box = card.getBoundingClientRect();
        const top = card.firstElementChild.getBoundingClientRect().top - box.top;
        const bottom = box.bottom - card.lastElementChild.getBoundingClientRect().bottom;
        return [!!card.querySelector(".jt-card__meta"), Math.round(top - bottom)];
      })()
    JS
    expect(card).to eq([false, 0])
    expect_no_theme_errors
  end

  # With core's "support mixed text direction" on, an English excerpt in a
  # Hebrew interface still ran right to left on the card, so the "…" where it
  # was cut short went before the text. It takes its own direction from its
  # text now; with the setting off it keeps the interface's, as core does.
  it "runs a card's excerpt in its own direction when mixed text direction is on" do
    # a fabricated post doesn't set its topic's excerpt
    topic.update!(
      excerpt: "I'm setting up a flip phone and want something that blocks the browser.",
    )
    SiteSetting.default_locale = "he"
    # how far the excerpt's text starts from its left edge
    start = <<~JS
      (() => {
        const excerpt = [...document.querySelectorAll(".jt-card .topic-excerpt")].find((e) =>
          e.textContent.includes("blocks the browser")
        );
        const text = document.createRange();
        text.selectNodeContents(excerpt.firstElementChild);
        return Math.round(text.getClientRects()[0].left - excerpt.getBoundingClientRect().left);
      })()
    JS

    visit("/latest")
    expect(page).to have_css("html.rtl .jt-card .topic-excerpt", text: "blocks the browser")
    expect(page).to have_no_css("html.jt-mixed-direction")
    expect(page.evaluate_script(start)).to be > 0

    SiteSetting.support_mixed_text_direction = true
    visit("/latest")
    expect(page).to have_css("html.jt-mixed-direction .jt-card .topic-excerpt")
    expect(page.evaluate_script(start)).to eq(0)
    expect_no_theme_errors
  end

  # In Hebrew core mirrors arrow-like icons with a transform; a pressed
  # button's 1px nudge was a transform too and replaced it, so Reply's arrow
  # flipped round for as long as it was held
  it "keeps a mirrored icon mirrored while its button is pressed" do
    SiteSetting.default_locale = "he"
    sign_in(member)
    visit(topic.relative_url)
    find("html.rtl #topic-footer-buttons .create .d-icon-reply", match: :first).hover
    page.driver.with_playwright_page { |pw| pw.mouse.down }
    transform = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("#topic-footer-buttons .create .d-icon-reply")).transform
    JS
    expect(transform).to start_with("matrix(-1")
  end

  # The card's pills were the theme's own English words, so a Hebrew list
  # said "Pinned"; core's word comes translated
  it "labels a card's pills in the interface's language" do
    SiteSetting.default_locale = "he"
    topic.update!(pinned_at: 1.hour.ago, pinned_globally: true)
    visit("/latest")
    expect(page).to have_css(
      "html.rtl .jt-card .jt-pill",
      text: I18n.t("js.topic_statuses.pinned.title", locale: :he),
    )
    expect(page).to have_no_css(".jt-card .jt-pill", text: "Pinned")
  end

  # Core floats "See 1 new or updated topic" over the list's header row on
  # wide screens; card lists have none, so it sat on the first card.
  it "keeps the new topics button above the first card, not on it" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".topic-list.jt-cards .topic-list-item")
    PostCreator.create!(
      admin,
      title: "A topic posted while the list is open",
      raw: "Posted while someone had the list open.",
      category: category.id,
    )
    expect(page).to have_css(".show-more.has-topics .alert")
    gap = page.evaluate_script(<<~JS)
      document.querySelector(".topic-list.jt-cards .topic-list-item").getBoundingClientRect().top -
        document.querySelector(".show-more .alert").getBoundingClientRect().bottom
    JS
    expect(gap).to be >= 0
    shot("new-topics-button")
    expect_no_theme_errors
  end

  it "starts a topic in the tag being viewed from the header's +" do
    sign_in(member)
    visit("/tag/#{tag.name}")
    find(".jt-header-new-topic button").click
    expect(page).to have_css("#reply-control.open")
    expect(page).to have_css("#reply-control .mini-tag-chooser", text: tag.name)
    expect_no_theme_errors
  end

  # A search result whose topic has no status icon kept the empty statuses
  # <span> before its title, which took the row's gap: the title sat 8px in
  # from the category line and the excerpt under it
  it "lines a search result's title up with the lines under it" do
    SearchIndexer.enable
    SearchIndexer.index(topic, force: true)
    SearchIndexer.index(first_post, force: true)
    sign_in(member)
    visit("/search?q=flip%20phone")
    expect(page).to have_css(".fps-result .search-link .topic-title", text: topic.title)
    offset = page.evaluate_script(<<~JS)
      (() => {
        const result = [...document.querySelectorAll(".fps-result")].find((r) =>
          r.querySelector(".search-link .topic-title")
        );
        return Math.round(
          result.querySelector(".search-link .topic-title").getBoundingClientRect().left -
            result.querySelector(".search-category").getBoundingClientRect().left
        );
      })()
    JS
    expect(offset).to eq(0)
    expect_no_theme_errors
  ensure
    SearchIndexer.disable
  end

  # Core's progress widget on phones is a row of boxes with the accent on its
  # numbers; the theme makes it one hairline capsule with tabular numbers.
  it "shows the phone's progress widget as one capsule", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#topic-progress .nums")
    border, radius, numerals = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector("#topic-progress-wrapper")).borderTopWidth,
        parseFloat(getComputedStyle(document.querySelector("#topic-progress-wrapper")).borderTopLeftRadius),
        getComputedStyle(document.querySelector("#topic-progress .nums")).fontVariantNumeric,
      ]
    JS
    expect(border).to eq("1px")
    expect(radius).to be > 4
    expect(numerals).to eq("tabular-nums")
    expect_no_theme_errors
  end

  # Core gives a pressed row of a table list (suggested topics) nothing, and
  # marks the row you came back to with a bar down one side of its first cell
  it "sinks a pressed suggested topic's row, and tints a selected one all across" do
    sign_in(member)
    visit(topic.relative_url)
    row = ".more-topics__container .topic-list-item"
    expect(page).to have_css(row, minimum: 2)
    page.execute_script(
      "document.querySelector(#{row.to_json}).scrollIntoView({ block: 'center' })",
    )
    x, y = page.evaluate_script(<<~JS)
      (() => {
        const box = document.querySelector("#{row} .num.views").getBoundingClientRect();
        return [box.x + box.width / 2, box.y + box.height / 2];
      })()
    JS
    scale = "getComputedStyle(document.querySelector(#{row.to_json})).scale"

    # pressed and held; let go elsewhere, so it doesn't open the topic
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(x, y)
      pw.mouse.down
    end
    try_until_success { expect(page.evaluate_script(scale)).to eq("0.985") }
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(1, 1)
      pw.mouse.up
    end
    try_until_success { expect(page.evaluate_script(scale)).to eq("none") }

    selected = page.evaluate_script(<<~JS)
      (() => {
        const [first, second] = document.querySelectorAll("#{row}");
        second.classList.add("selected");
        return [
          getComputedStyle(second.querySelector("td")).boxShadow,
          getComputedStyle(second).backgroundColor !== getComputedStyle(first).backgroundColor,
        ];
      })()
    JS
    expect(selected).to eq(["none", true])
    expect_no_theme_errors
  end

  # hide_lock_icons hid every lock in a sidebar link, the Security link's own
  # icon among them (user navigation in the sidebar); and the device menu on
  # that page was a 12rem empty box, as wide as the page's text dropdowns
  it "keeps the Security link's lock, hides a private category's, and a compact device menu" do
    SiteSetting.sidebar_user_navigation = true
    group = Fabricate(:group).tap { |g| g.add(admin) }
    private_category = Fabricate(:private_category, group: group, name: "Inner circle")
    SidebarSectionLink.create!(user: admin, linkable: private_category)
    UserAuthToken.generate!(
      user_id: admin.id,
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0 Safari/537.36",
      client_ip: "203.0.113.7",
    )
    sign_in(admin)

    visit("/latest")
    padlock = ".sidebar-section-link .prefix-badge"
    expect(page).to have_css(padlock, visible: :all)
    expect(
      page.evaluate_script("getComputedStyle(document.querySelector(#{padlock.to_json})).display"),
    ).to eq("none")

    visit("/u/#{admin.username}/preferences/security")
    lock = ".sidebar-section-link[data-link-name='user-nav-preferences-security'] .prefix-icon"
    expect(page).to have_css(lock)
    expect(page).to have_css(".pref-auth-tokens .auth-token-dropdown")
    width = page.evaluate_script(<<~JS)
      document.querySelector(".pref-auth-tokens .auth-token-dropdown").getBoundingClientRect().width
    JS
    expect(width).to be < 60
    expect_no_theme_errors
  end

  # A square logo with hard corners looked cut out; it's an app icon
  it "draws the square logo on a phone in the theme's squircle", mobile: true do
    SiteSetting.logo_small = Fabricate(:image_upload)
    visit("/latest")
    expect(page).to have_css(".d-header img.logo-mobile")
    radius = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".d-header img.logo-mobile")).borderTopLeftRadius
    JS
    expect(radius).not_to eq("0px")
    expect_no_theme_errors
  end

  # Who's Online's row of avatars sat over the topic list, in the tabs' way.
  # Beside the tabs' dropdown, "Online: 1" and the faces of the people online
  # in a row, shown at all times, the row taking the room up to New Topic.
  # Only where the plugin is installed (CI doesn't have it).
  it "shows who's online beside the tabs as a row of faces" do
    skip("needs the Who's Online plugin") unless defined?(::DiscourseWhosOnline)
    SiteSetting.whos_online_enabled = true
    SiteSetting.whos_online_display_public = true
    SiteSetting.whos_online_minimum_display = 1
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-online-box__label", exact_text: "Online: 1")
    # folded until the count is clicked
    expect(page).to have_no_css(".jt-online-box__people")
    find(".jt-online-box__label").click
    expect(page).to have_css(
      ".jt-online-box__people a[href='/u/#{member.username}'] img.jt-online-box__face",
    )
    expect(page).to have_no_css(".online_users_widget", visible: true)
    tops, overflow = page.evaluate_script(<<~JS)
      [
        [".category-breadcrumb", "#navigation-bar", "#create-topic"].map((s) =>
          Math.round(document.querySelector(`.list-controls ${s}`).getBoundingClientRect().top)
        ),
        document.documentElement.scrollWidth - window.innerWidth,
      ]
    JS
    expect(tops.uniq.size).to eq(1)
    expect(overflow).to eq(0)
    expect_no_theme_errors
  end

  # The jump arrows were 16px tall at the top of the capsule (a height of
  # 100% with nothing to measure against), above the wrench and the counter
  it "lines the capsule's arrows, wrench and counter up at one height", mobile: true do
    sign_in(admin)
    visit(topic.relative_url)
    expect(page).to have_css("#topic-progress-wrapper .jt-jump__bottom")
    expect(page).to have_css("#topic-progress-wrapper .toggle-admin-menu")
    boxes = page.evaluate_script(<<~JS)
      [".jt-jump__top", ".jt-jump__bottom", ".toggle-admin-menu", "#topic-progress"].map((s) => {
        const box = document.querySelector(`#topic-progress-wrapper ${s}`).getBoundingClientRect();
        return [Math.round(box.top), Math.round(box.height)];
      })
    JS
    expect(boxes.uniq.size).to eq(1)
    expect(boxes.first.last).to be >= 36
    expect_no_theme_errors
  end

  # Core's status bubble sits off the avatar's top corner; with the theme's
  # avatar inside the card it covered the name row, leaving only the staff
  # shield showing
  it "keeps a status bubble off the name on a user card" do
    SiteSetting.enable_user_status = true
    admin.set_status!("Nothing but popcorn at a zoo.", "popcorn")
    sign_in(member)
    visit(topic.relative_url)
    find("#post_2 .topic-avatar a").click
    expect(page).to have_css("#user-card .user-status")
    bubble_bottom, name_top = page.evaluate_script(<<~JS)
      [
        document.querySelector("#user-card .user-status").getBoundingClientRect().bottom,
        document.querySelector("#user-card .names__primary").getBoundingClientRect().top,
      ]
    JS
    expect(name_top).to be >= bubble_bottom - 1
    expect_no_theme_errors
  end

  # Core shows the keyboard-shortcuts button whenever it takes the page for a
  # desktop one, by width: a big phone or a phone turned sideways got it
  it "leaves the keyboard-shortcuts button out of the sidebar on a touch screen" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".sidebar-footer-actions-keyboard-shortcuts")
    # The test browser can't take a touch screen's pointer, so this reads the
    # rule the page applies under one
    hidden_on_touch = page.evaluate_script(<<~'JS')
      [...document.styleSheets].some((sheet) => {
        let rules;
        try { rules = [...sheet.cssRules]; } catch { return false; }
        const walk = (list, touch) =>
          list.some((rule) => {
            const media = rule instanceof CSSMediaRule ? rule.conditionText : "";
            const inTouch = touch || (/hover:\s*none/.test(media) && /pointer:\s*coarse/.test(media));
            // style rules have a (nesting) list of their own too, mostly empty
            if (rule.cssRules?.length) return walk([...rule.cssRules], inTouch);
            return (
              inTouch &&
              rule.selectorText?.includes(".sidebar-footer-actions-keyboard-shortcuts") &&
              rule.style.display === "none"
            );
          });
        return walk(rules, false);
      })
    JS
    expect(hidden_on_touch).to eq(true)
    expect_no_theme_errors
  end

  # At the end of a topic the capsule came to rest above the buttons under the
  # topic, a second row with a second admin wrench, and on a 390px phone
  # Reply wrapped under the icons. While those buttons show the capsule steps
  # aside, leaving no gap, and the buttons are one row with Reply.
  it "keeps the end of a topic to one row of buttons on a phone", mobile: true do
    6.times { |i| Fabricate(:post, topic: topic, raw: "Reply #{i}. " + "A line. " * 60) }
    sign_in(admin)
    resize_window(width: 390, height: 844) do
      visit(topic.relative_url)
      expect(page).to have_css("#topic-progress-wrapper")
      page.execute_script(<<~JS)
        const footer = document.getElementById("topic-footer-buttons");
        window.scrollTo(0, footer.getBoundingClientRect().top + scrollY - 400);
      JS
      expect(page).to have_css("html.jt-topic-end")
      capsule, icons, reply, gap = page.evaluate_script(<<~JS)
        (() => {
          const top = (s) => Math.round(document.querySelector(s).getBoundingClientRect().top);
          return [
            getComputedStyle(document.querySelector("#topic-progress-wrapper")).visibility,
            top("#topic-footer-buttons .topic-footer-main-buttons__actions"),
            top("#topic-footer-buttons .topic-footer-main-buttons > .create"),
            document.documentElement.scrollWidth - window.innerWidth,
          ];
        })()
      JS
      expect(capsule).to eq("hidden")
      expect(reply).to be_within(4).of(icons)
      expect(gap).to eq(0)
      expect_no_theme_errors
    end
  end

  # On a phone the timeline opens as a sheet, where core's own rule makes its
  # controls a wrapping row: at 320px the last-post arrow wrapped alone, under
  # Jump to… and the first-post arrow
  it "keeps the timeline sheet's arrows together on a 320px phone", mobile: true do
    sign_in(member)
    resize_window(width: 320) do
      visit(topic.relative_url)
      find("#topic-progress").click
      expect(page).to have_css(".timeline-container.timeline-fullscreen.show .jt-jump__bottom")
      tops = page.evaluate_script(<<~JS)
        [".jt-jump__top", ".jt-jump__bottom"].map((arrow) =>
          Math.round(document.querySelector(`.timeline-fullscreen ${arrow}`).getBoundingClientRect().top)
        )
      JS
      expect(tops.uniq.size).to eq(1)
      expect_no_theme_errors
    end
  end

  # Only the title opened a topic in a row list (New & Unread under a topic,
  # stock rows, compact density): the rest of the row did nothing
  it "opens a topic from anywhere on its row, not only its title" do
    sign_in(member)
    visit(topic.relative_url)
    row = find("#suggested-topics .topic-list-item", match: :first)
    id = row["data-topic-id"]
    row.find("td.num.views").click
    expect(page).to have_current_path(%r{/t/[^/]+/#{id}})
    expect_no_theme_errors
  end

  # "New & Unread Topics" under a topic had no way to clear them: each one had
  # to be opened to go away
  it "dismisses the new and unread topics under a topic in one go" do
    unread =
      Array.new(2) do |i|
        t = Fabricate(:topic, category: category, user: admin, title: "Unread guide part #{i + 1}")
        Fabricate(:post, topic: t, user: admin, raw: "The first part of this guide.")
        PostTiming.process_timings(member, t.id, 1000, [[1, 1000]])
        TopicUser.change(
          member.id,
          t.id,
          notification_level: TopicUser.notification_levels[:tracking],
        )
        Fabricate(:post, topic: t, user: admin, raw: "A new reply to this guide.")
        t
      end
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#suggested-topics a.badge-notification")

    find(".jt-dismiss-unread__button").click
    find(".dialog-footer .btn-primary").click
    expect(page).to have_no_css("#suggested-topics a.badge-notification")
    expect(page).to have_no_css(".jt-dismiss-unread")
    try_until_success do
      expect(TopicUser.where(user: member, topic: unread).pluck(:last_read_post_number)).to all(
        eq(2),
      )
    end
    expect_no_theme_errors
  end

  # The footer under search results ("No more results found.", and empty while
  # more can load) is an <h3> alone in its container, like the Users and
  # Categories & tags tabs' "No results", and came out as that big card
  it "keeps the footer under search results a quiet line, not a card" do
    SearchIndexer.enable
    SearchIndexer.index(topic, force: true)
    SearchIndexer.index(first_post, force: true)
    sign_in(member)
    visit("/search?q=flip%20phone")
    expect(page).to have_css(".search-footer", text: I18n.t("js.search.no_more_results"))
    footer = page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.querySelector(".search-footer"));
        return [style.borderTopWidth, style.backgroundColor];
      })()
    JS
    expect(footer).to eq(["0px", "rgba(0, 0, 0, 0)"])
    expect_no_theme_errors
  ensure
    SearchIndexer.disable
  end

  # Core marks the selected tab with a solid 2px bar. The theme: a 1px line
  # that glows, with a faint light behind the label. (The topic list's tabs
  # are a dropdown; a profile's are a row.)
  it "marks the selected tab with a thin glowing line" do
    sign_in(member)
    visit("/u/#{member.username}/summary")
    expect(page).to have_css(".user-navigation .nav-pills > li > a.active")
    tab = page.evaluate_script(<<~JS)
      (() => {
        const tab = document.querySelector(".user-navigation .nav-pills > li > a.active");
        const line = getComputedStyle(tab, "::after");
        return {
          line: line.height,
          glow: line.boxShadow !== "none",
          light: getComputedStyle(tab).backgroundImage.startsWith("radial-gradient"),
        };
      })()
    JS
    expect(tab).to eq("line" => "1px", "glow" => true, "light" => true)
    expect_no_theme_errors
  end

  # "Back" floats above the phone's progress capsule; matched with the
  # capsule's own buttons it lost its fill and showed as bare grey text over
  # the post below. Core only shows it after some jumps, so the spec adds the
  # same markup core renders and checks its look.
  it "draws the phone's Back button as a pill of its own", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#topic-progress-wrapper")
    back = page.evaluate_script(<<~JS)
      (() => {
        const container = document.createElement("div");
        container.className = "progress-back-container";
        container.innerHTML = '<button class="btn btn-icon-text btn-primary btn-small progress-back" type="button"><span class="d-button-label">Back</span></button>';
        document.querySelector("#topic-progress-wrapper").appendChild(container);
        const style = getComputedStyle(container.querySelector(".btn"));
        const look = { fill: style.backgroundColor, height: parseFloat(style.height), border: style.borderTopWidth };
        container.remove();
        return look;
      })()
    JS
    expect(back["fill"]).not_to eq("rgba(0, 0, 0, 0)")
    expect(back["height"]).to be >= 30
    expect(back["border"]).to eq("1px")
    expect_no_theme_errors
  end

  it "sends links that aren't forum pages to the browser" do
    visit("/latest")
    expect(page).to have_css(".jt-header-home a[href='/home'][data-auto-route='true']")
    expect(page).to have_css(".jt-footer a[href='/latest']:not([data-auto-route])")
  end

  # The footer had no way to log in, or to one's own profile, messages,
  # bookmarks and preferences, and none back to the top; the AI and scraping
  # notice sat in a band of its own above it
  it "gives the footer an Account column, its small print and a way back to the top" do
    visit("/latest")
    account = find(".jt-footer__column", text: "Account")
    expect(account).to have_link("Log in", href: "/login")
    expect(account).to have_link("Sign up", href: "/signup")
    # before Legal
    headings = all(".jt-footer__heading").map(&:text)
    expect(headings.index("Account")).to eq(headings.index("Legal") - 1)

    sign_in(member)
    visit("/latest")
    account = find(".jt-footer__column", text: "Account")
    expect(account).to have_link("Profile", href: "/u/#{member.username}/summary")
    expect(account).to have_link("Messages", href: "/u/#{member.username}/messages")
    expect(account).to have_link("Bookmarks", href: "/u/#{member.username}/activity/bookmarks")
    expect(account).to have_no_link("Log in")

    # the small print on the last line, with its Terms link
    expect(page).to have_css(".jt-footer__base .jt-footer__notice", text: "AI training")
    expect(page).to have_css(".jt-footer__notice a[href='/tos']", text: "Terms")

    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    find(".jt-footer__top").click
    try_until_success { expect(page.evaluate_script("window.scrollY")).to be < 10 }
    expect_no_theme_errors
  end

  it "draws the theme's own shortcuts in the ? help like core's" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    find("body").send_keys("?")
    expect(page).to have_css(".keyboard-shortcuts-modal .delimiter-space kbd.d-shortcut")
    spacing = page.evaluate_script(<<~JS)
      (() => {
        const rows = [...document.querySelectorAll(".keyboard-shortcuts-modal tr")];
        const gap = (name) => {
          const row = rows.find((r) => r.querySelector(".shortcut-description")?.textContent.trim() === name);
          const [a, b] = row.querySelectorAll(".d-shortcut__key");
          return Math.round(b.getBoundingClientRect().left - a.getBoundingClientRect().right);
        };
        return { core: gap("Home"), theme: gap("Tags") };
      })()
    JS
    expect(spacing["theme"]).to eq(spacing["core"])
    expect_no_theme_errors
  end

  it "gives the header and sidebar room: core's 16px text, 40px header controls, 36px rows" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".sidebar-section-link")
    root, header, control, glyph, row, label = page.evaluate_script(<<~JS)
      (() => {
        const size = (s) => document.querySelector(s).getBoundingClientRect();
        return [
          parseFloat(getComputedStyle(document.documentElement).fontSize),
          size(".d-header").height,
          size(".d-header-icons .jt-header-notifications > .icon").height,
          size(".d-header-icons .jt-header-notifications .d-icon").width,
          size(".sidebar-section-link").height,
          parseFloat(getComputedStyle(document.querySelector(".sidebar-section-link")).fontSize),
        ].map(Math.round);
      })()
    JS
    expect(root).to eq(16)
    expect(header).to be >= 60
    expect(control).to eq(40)
    expect(glyph).to eq(18)
    expect(row).to eq(36)
    expect(label).to eq(16)
    expect_no_theme_errors
  end

  # Hebrew is offered, and picked from the browser's language. In a
  # right-to-left interface core's stylesheet flipping turned the centred
  # search field's left: 50% into right: 50% but kept its -50% shift, which put
  # the field 330px off centre, over the header's buttons
  it "centres the header's search field in a right-to-left interface" do
    SiteSetting.allow_user_locale = true
    member.update!(locale: "he")
    sign_in(member)
    visit("/latest")
    expect(page).to have_css("html.rtl .jt-header-search--centered .jt-header-search__button")
    offset = page.evaluate_script(<<~JS)
      (() => {
        const field = document.querySelector(".jt-header-search--centered").getBoundingClientRect();
        const bar = document.querySelector(".d-header .contents").getBoundingClientRect();
        return Math.round((field.left + field.right) / 2 - (bar.left + bar.right) / 2);
      })()
    JS
    expect(offset.abs).to be <= 1
    expect_no_theme_errors
  end

  describe "header icons" do
    # Every visible icon in the header row, the theme's and core's and chat's:
    # one glyph size, one vertical centre. The desktop search field has its
    # own, smaller magnifier.
    def header_glyphs(skip: ".current-user")
      page.evaluate_script(<<~JS)
        [...document.querySelectorAll(".d-header-icons > li:not(#{skip}) svg.d-icon")]
          .map((svg) => svg.getBoundingClientRect())
          .filter((r) => r.width > 0)
          .map((r) => [Math.round(r.width), Math.round(r.top + r.height / 2)])
      JS
    end

    before do
      SiteSetting.chat_enabled = true
      SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
      sign_in(member)
    end

    it "are all one size" do
      jtech_theme.update_setting(:header_color_toggle, true) # light/dark is measured too
      jtech_theme.save!
      visit("/latest")
      expect(page).to have_css(".jt-header-theme .d-icon")
      expect(page).to have_css(".chat-header-icon .d-icon")
      glyphs = header_glyphs(skip: ".current-user, .jt-header-search")
      expect(glyphs.size).to be >= 5
      expect(glyphs.uniq.size).to eq(1)
    end

    it "are all one size on phones", mobile: true do
      visit("/latest")
      expect(page).to have_css(".hamburger-dropdown .d-icon")
      glyphs = header_glyphs
      expect(glyphs.size).to be >= 4
      expect(glyphs.uniq.size).to eq(1)
    end
  end

  # The theme keeps thin scrollbars visible on touch screens, except under a
  # post's row of buttons, which scrolls sideways by a few pixels on phones.
  # Small controls on phones get a hit area of at least 32px without growing
  # (they were 16-22px): measured as how far above and below a control's
  # centre a tap still lands on it.
  it "gives small controls on phones a finger-sized hit area", mobile: true do
    reach = <<~JS
      ((selector) => {
        const el = document.querySelector(selector);
        el.scrollIntoView({ block: "center" });
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2;
        const y = r.top + r.height / 2;
        const on = (dy) => {
          const hit = document.elementFromPoint(x, y + dy);
          return hit === el || el.contains(hit);
        };
        let up = 0;
        let down = 0;
        while (up < 40 && on(-(up + 1))) up++;
        while (down < 40 && on(down + 1)) down++;
        return Math.round(up + down + 1);
      })
    JS
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card .jt-card__peek")
    expect(page.evaluate_script("#{reach}('.jt-card__peek')")).to be >= 30
    expect(page.evaluate_script("#{reach}('.jt-card .badge-category__wrapper')")).to be >= 30

    visit(topic.relative_url)
    expect(page).to have_css(".topic-post .post-info.post-date a.post-date")
    expect(
      page.evaluate_script("#{reach}('.topic-post .post-info.post-date a.post-date')"),
    ).to be >= 30
    expect_no_theme_errors
  end

  it "draws no scrollbar under a post's buttons on phones", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".topic-post .post-controls")
    scrollbar = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".topic-post .post-controls")).scrollbarWidth
    JS
    expect(scrollbar).to eq("none")
    expect_no_theme_errors
  end

  it "draws trust-level and staff flair in black and white, with its own marks" do
    Group.refresh_automatic_groups!
    Group.find(Group::AUTO_GROUPS[:trust_level_2]).update!(
      flair_icon: "thumbs-up",
      flair_bg_color: "9CA3AF",
      flair_color: "FFFFFF",
    )
    Group.find(Group::AUTO_GROUPS[:admins]).update!(
      flair_icon: "shield-halved",
      flair_bg_color: "5A29E4",
      flair_color: "FFFFFF",
    )
    member.update!(flair_group_id: Group::AUTO_GROUPS[:trust_level_2])
    admin.update!(flair_group_id: Group::AUTO_GROUPS[:admins])

    visit(topic.relative_url)
    expect(page).to have_css("#post_1 .avatar-flair-trust_level_2")
    expect(page).to have_css("#post_2 .avatar-flair-admins")
    backgrounds, icons, glyphs = page.evaluate_script(<<~JS)
      (() => {
        const flairs = ["#post_1", "#post_2"].map((post) =>
          document.querySelector(`${post} .topic-avatar .avatar-flair`)
        );
        return [
          flairs.map((flair) => getComputedStyle(flair).backgroundColor),
          flairs.map((flair) => getComputedStyle(flair.querySelector("svg")).display),
          flairs.map((flair) => {
            const glyph = getComputedStyle(flair, "::before");
            return (glyph.maskImage || glyph.webkitMaskImage).startsWith('url("data:image/svg+xml');
          }),
        ];
      })()
    JS
    expect(backgrounds).not_to include("rgb(156, 163, 175)", "rgb(90, 41, 228)")
    expect(backgrounds.uniq.size).to eq(2) # staff are inverted
    expect(icons).to eq(%w[none none])
    expect(glyphs).to eq([true, true])
    shot("flair")
    expect_no_theme_errors
  end

  describe "what used to be separate components" do
    fab!(:lonely_topic) do
      Fabricate(:topic, category: category, user: admin, title: "A topic nobody answered yet")
    end
    fab!(:lonely_post) do
      Fabricate(
        :post,
        topic: lonely_topic,
        user: admin,
        raw:
          "Line one of the guide.\n\n```bash\necho one\necho two\necho three\n```\n\nSee [the homepage](/home) or [latest](/latest).",
      )
    end

    it "prompts for the first reply and numbers code lines" do
      sign_in(member)
      visit(lonely_topic.relative_url)
      expect(page).to have_css(".jt-first-reply", text: "No replies yet. Be the first.")
      expect(page).to have_css("pre.jt-numbered .jt-lines", text: "1\n2\n3")
      shot("first-reply")
      expect_no_theme_errors
    end

    # The prompt was a dashed card, which read as an empty slot; and Solved's
    # Me too a full bordered button beside the reaction counts
    it "keeps the first-reply prompt to a line, and Me too to a small pill" do
      category.custom_fields["enable_accepted_answers"] = "true"
      category.save_custom_fields(true)
      lonely_topic.update!(category: category)
      SiteSetting.solved_enabled = true
      SiteSetting.enable_solved_shared_issues = true
      DiscourseSolved::AcceptedAnswerCache.reset_accepted_answer_cache
      sign_in(member)
      visit(lonely_topic.relative_url)
      expect(page).to have_css(".jt-first-reply")
      expect(page).to have_css(".post-action-menu__solved-shared-issue")
      prompt, pill = page.evaluate_script(<<~JS)
        [".jt-first-reply", ".post-action-menu__solved-shared-issue"].map((selector) => {
          const style = getComputedStyle(document.querySelector(selector));
          return [style.borderTopStyle, style.backgroundColor, Math.round(parseFloat(style.height))];
        })
      JS
      expect(prompt[0..1]).to eq(["none", "rgba(0, 0, 0, 0)"])
      expect(pill[1]).to eq("rgba(0, 0, 0, 0)")
      expect(pill[2]).to be < 32
      expect_no_theme_errors
    end

    # Core scrolls <code> past 500px; the gutter used to keep every line's height
    # and stay put while the code scrolled
    it "scrolls a tall code block's line numbers with it, inside the box" do
      lines = (1..60).map { |i| "echo #{i}" }
      lines[0] += " #{"x" * 400}" # a long line, so the code has a horizontal scrollbar
      raw = "```bash\n#{lines.join("\n")}\n```"
      tall = Fabricate(:topic, category: category, user: admin)
      Fabricate(:post, topic: tall, user: admin, raw: raw)
      visit(tall.relative_url)
      expect(page).to have_css("pre.jt-numbered .jt-lines")
      sizes = page.evaluate_async_script(<<~JS)
        const [pre] = document.getElementsByClassName("jt-numbered");
        const code = pre.querySelector(":scope > code");
        const gutter = pre.querySelector(":scope > .jt-lines");
        code.scrollTop = code.scrollHeight;
        requestAnimationFrame(() => requestAnimationFrame(() => arguments[0]([
          code.clientHeight, gutter.offsetHeight, pre.offsetHeight, code.scrollTop, gutter.scrollTop,
        ])));
      JS
      code_height, gutter_height, pre_height, code_top, gutter_top = sizes
      expect(gutter_height).to be_within(1).of(code_height) # ends above the code's scrollbar
      expect(pre_height).to be <= code_height + 40 # the box's border and the scrollbar
      expect(code_top).to be > 0
      expect(gutter_top).to be_within(1).of(code_top)
    end

    # Code runs left to right in any interface, but core's right-to-left
    # stylesheet flips left and right: in Hebrew the line between the numbers
    # and the code moved onto the block's outer edge, and on a phone the room
    # kept clear of the copy button moved to the left, away from the button
    it "keeps a numbered code block's sides in a Hebrew interface", mobile: true do
      SiteSetting.support_mixed_text_direction = true # as on the forum: code runs left to right
      SiteSetting.default_locale = "he"
      visit(lonely_topic.relative_url)
      expect(page).to have_css("html.rtl pre.jt-numbered.codeblock-buttons .jt-lines")
      sides = page.evaluate_script(<<~JS)
        (() => {
          const gutter = getComputedStyle(document.querySelector("pre.jt-numbered .jt-lines"));
          const code = getComputedStyle(document.querySelector("pre.jt-numbered > code"));
          return [
            gutter.borderRightWidth,
            gutter.borderLeftWidth,
            parseFloat(code.paddingRight) > parseFloat(code.paddingLeft),
          ];
        })()
      JS
      expect(sides).to eq(["1px", "0px", true])
      expect_no_theme_errors
    end

    it "doesn't prompt once someone has replied" do
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".topic-post")
      expect(page).to have_no_css(".jt-first-reply")
    end

    it "opens links to non-forum pages in posts as a page load" do
      visit(lonely_topic.relative_url)
      expect(page).to have_css(".cooked a[href='/home'][data-auto-route='true']")
      expect(page).to have_css(".cooked a[href='/latest']:not([data-auto-route])")
    end

    it "shows jump buttons under the timeline, a 2×2 block with core's buttons" do
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".timeline-container .jt-jump .jt-jump__bottom")
      # reply · notifications over first post · last post, all one size
      reply, bell, top, bottom = page.evaluate_script(<<~JS)
        [".reply-to-post", ".notifications-tracking-trigger", ".jt-jump__top", ".jt-jump__bottom"]
          .map((selector) => document.querySelector(`.timeline-footer-controls ${selector}`))
          .map((b) => b.getBoundingClientRect())
          .map((r) => [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)])
      JS
      expect([reply, bell, top, bottom].map { |b| b[2..] }.uniq.size).to eq(1)
      expect(bell[1]).to eq(reply[1])
      expect([top[0], top[1] > reply[1]]).to eq([reply[0], true])
      expect([bottom[0], bottom[1]]).to eq([bell[0], top[1]])
      # flush with the timeline's left edge, under the buttons at its top
      timeline_left =
        page.evaluate_script(
          "Math.round(document.querySelector('.topic-timeline').getBoundingClientRect().left)",
        )
      expect(reply[0]).to eq(timeline_left)
      expect_no_theme_errors
    end

    # A long topic's Top replies took the first column (widening ↑ under it)
    # and pushed notifications onto a row of its own
    it "keeps the 2×2 block under Top replies on a long topic" do
      SiteSetting.summary_timeline_button = true
      topic.update!(has_summary: true)
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".timeline-container .show-summary")
      expect(page).to have_css(".timeline-container .jt-jump .jt-jump__bottom")
      summary, reply, bell, top, bottom = page.evaluate_script(<<~JS)
        [".show-summary", ".reply-to-post", ".notifications-tracking-trigger", ".jt-jump__top", ".jt-jump__bottom"]
          .map((selector) => document.querySelector(`.timeline-footer-controls ${selector}`))
          .map((b) => b.getBoundingClientRect())
          .map((r) => [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)])
      JS
      expect([reply, bell, top, bottom].map { |b| b[2..] }.uniq.size).to eq(1)
      expect(summary[1]).to be < reply[1]
      expect(bell[1]).to eq(reply[1])
      expect([top[0], bottom[0], bottom[1]]).to eq([reply[0], bell[0], top[1]])
      expect(top[1]).to be > reply[1]
      expect_no_theme_errors
    end

    it "copies a post's Markdown from the post menu" do
      sign_in(member)
      visit(topic.relative_url)
      cdp = PageObjects::CDP.new
      cdp.allow_clipboard
      find("#post_1 .post-action-menu__jt-copy-post").click
      expect(page).to have_css(
        "#post_1 .post-action-menu__jt-copy-post .post-action-feedback-alert",
      )
      cdp.clipboard_has_text?(first_post.raw)
      expect_no_theme_errors
    end

    it "leaves the Copy button out for groups that aren't allowed it" do
      sign_in(Fabricate(:user, trust_level: TrustLevel[0]))
      visit(topic.relative_url)
      expect(page).to have_css("#post_1 .post-action-menu__copy-link")
      expect(page).to have_no_css(".post-action-menu__jt-copy-post")
    end

    it "warns when replying to a closed topic, and reopens it from the composer" do
      topic.update!(closed: true)
      sign_in(admin)
      visit(topic.relative_url)
      PageObjects::Pages::Topic.new.click_reply_button
      expect(page).to have_css(".composer-popup.jt-closed-reply-popup .jt-closed-reply p")
      shot("closed-reply-warning")
      find(".jt-closed-reply__open").click
      expect(page).to have_no_css(".jt-closed-reply-popup")
      expect(topic.reload.closed).to eq(false)
      expect_no_theme_errors
    end

    it "doesn't warn when replying to an open topic" do
      sign_in(admin)
      visit(topic.relative_url)
      PageObjects::Pages::Topic.new.click_reply_button
      expect(page).to have_css("#reply-control.open")
      expect(page).to have_no_css(".jt-closed-reply-popup")
    end

    it "searches the forum for text selected in a post" do
      sign_in(member)
      visit(topic.relative_url)
      select_text_range("#post_1 .cooked p", 4, 7) # "setting"
      find(".jt-selection-search").click
      expect(page).to have_current_path("/search?q=setting")
      expect_no_theme_errors
    end

    it "filters a topic list to the topics nobody has replied to" do
      visit("/latest")
      filter = PageObjects::Components::SelectKit.new(".jt-replies-filter")
      filter.expand
      filter.select_row_by_value("none")
      expect(page).to have_current_path("/latest?max_posts=1")
      expect(page).to have_css(".topic-list-item[data-topic-id='#{lonely_topic.id}']")
      expect(page).to have_no_css(".topic-list-item[data-topic-id='#{topic.id}']")
      filter.expand
      filter.select_row_by_value("with")
      expect(page).to have_current_path("/latest?min_posts=2")
      expect(page).to have_css(".topic-list-item[data-topic-id='#{topic.id}']")
      expect(page).to have_no_css(".topic-list-item[data-topic-id='#{lonely_topic.id}']")
      expect_no_theme_errors
    end

    it "prints a topic's first post on its own in the chosen categories" do
      jtech_theme.update_setting(:print_button_categories, category.id.to_s)
      jtech_theme.save!
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css("#post_1 .post-action-menu__jt-print")
      expect(page).to have_css("#post_2 .post-action-menu__copy-link")
      expect(page).to have_no_css("#post_2 .post-action-menu__jt-print")
      # the browser's print dialog can't be driven: the frame's print() is
      # swapped for a marker as soon as the frame is added
      page.execute_script(<<~JS)
        new MutationObserver(() => {
          const frame = document.querySelector(".jt-print-frame");
          if (frame && !frame.dataset.stubbed) {
            frame.dataset.stubbed = "true";
            frame.contentWindow.print = () => (document.body.dataset.jtPrinted = "true");
          }
        }).observe(document.body, { childList: true });
      JS
      find("#post_1 .post-action-menu__jt-print").click
      expect(page).to have_css("body[data-jt-printed='true']")
      printed = page.evaluate_script(<<~JS)
        (() => {
          const doc = document.querySelector(".jt-print-frame").contentDocument;
          return [doc.compatMode, doc.querySelector(".jt-print__title").textContent,
            doc.querySelector(".jt-print .cooked").textContent.includes("blocks the browser")];
        })()
      JS
      expect(printed).to eq(["CSS1Compat", topic.title, true])
      expect_no_theme_errors
    end

    it "leaves Print out of categories that aren't chosen" do
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css("#post_1 .post-action-menu__copy-link")
      expect(page).to have_no_css(".post-action-menu__jt-print")
    end

    it "shows the listed badges after a poster's name" do
      badge = Fabricate(:badge, name: "Phone Distributor", icon: "certificate")
      BadgeGranter.grant(badge, member)
      jtech_theme.update_setting(:post_badges, "Sonim Engineer|Phone Distributor")
      jtech_theme.save!
      visit(topic.relative_url)
      expect(page).to have_css(
        "#post_1 .jt-post-badge[title='Phone Distributor'][href$='/badges/#{badge.id}/#{badge.slug}']",
      )
      expect(page).to have_css("#post_2 .topic-meta-data")
      expect(page).to have_no_css("#post_2 .jt-post-badge")
      expect_no_theme_errors
    end

    it "shows a [wrap=Carousel] post's pictures as Discourse's carousel" do
      one = Fabricate(:image_upload)
      two = Fabricate(:image_upload)
      Fabricate(
        :post,
        topic: topic,
        user: member,
        raw:
          "[wrap=Carousel autoplay=false loop=true]\nThe phone, front and back.\n\n![front|690x460](#{one.short_url})\n![back|690x460](#{two.short_url})\n[/wrap]",
      )
      visit("#{topic.relative_url}/5")
      wrap = "#post_5 .d-wrap[data-wrap='Carousel']"
      expect(page).to have_css("#{wrap} .d-image-carousel .d-image-carousel__slide", count: 2)
      expect(page).to have_css("#{wrap} > p", text: "The phone, front and back.", count: 1)
      expect_no_theme_errors
    end

    it "lists the group inboxes someone has in the sidebar" do
      group = Fabricate(:group, name: "helpers", has_messages: true)
      group.add(admin)
      sign_in(admin)
      visit("/latest")
      inboxes = "[data-section-name='jt-inboxes']"
      expect(page).to have_css(
        "#{inboxes} .sidebar-section-link[href='/u/#{admin.username}/messages/group/helpers']",
      )
      expect(page).to have_css(
        "#{inboxes} .sidebar-section-link[href='/u/#{admin.username}/messages']",
      )
      expect_no_theme_errors
    end

    it "leaves the Inboxes section out for people without a group inbox" do
      sign_in(member)
      visit("/latest")
      expect(page).to have_css(".sidebar-sections")
      expect(page).to have_no_css("[data-section-name='jt-inboxes']")
    end

    it "switches a topic to reader mode from the timeline" do
      sign_in(member)
      visit(topic.relative_url)
      size = "parseFloat(getComputedStyle(document.querySelector('#post_1 .cooked')).fontSize)"
      normal = page.evaluate_script(size)
      body_width = "document.querySelector('#post_1 .topic-body').getBoundingClientRect().width"
      find(".jt-reader-toggle").click
      expect(page).to have_css("html.jt-reader")
      expect(page).to have_no_css(".sidebar-wrapper")

      # the reading column stands in the middle of the window (the timeline
      # hanging to its right), not at the window's left edge
      center, middle = page.evaluate_script(<<~JS)
        (() => {
          const avatar = document.querySelector("#post_1 .topic-avatar").getBoundingClientRect();
          const body = document.querySelector("#post_1 .topic-body").getBoundingClientRect();
          return [(avatar.left + body.right) / 2, window.innerWidth / 2];
        })()
      JS
      expect(center).to be_within(16).of(middle)

      # its settings, labelled, in the Aa menu
      find(".jt-reader-settings__trigger").click
      expect(page).to have_css(".jt-reader-menu__value", text: "100%")
      find(".jt-reader-larger").click
      try_until_success { expect(page.evaluate_script(size)).to be > normal }
      expect(page).to have_css(".jt-reader-menu__value", text: "113%")

      # and the width buttons change the column (they did nothing)
      before = page.evaluate_script(body_width)
      find(".jt-reader-narrower").click
      try_until_success { expect(page.evaluate_script(body_width)).to be < before - 20 }

      find(".jt-reader-serif").click
      expect(page).to have_css("html.jt-reader--serif")
      shot("reader-mode")
      find(".jt-reader-sans").click
      expect(page).to have_no_css("html.jt-reader--serif")
      find(".jt-reader-toggle").click
      expect(page).to have_no_css("html.jt-reader")
      expect(page).to have_css(".sidebar-wrapper")
      expect_no_theme_errors
    end

    it "offers a topic's link as a QR code among the share options" do
      sign_in(member)
      visit(topic.relative_url)
      find("#topic-footer-buttons .share-and-invite").click
      find(".share-topic-modal button[title='QR code']").click
      expect(page).to have_css(".d-modal.jt-qr .jt-qr__code svg path")
      expect(page).to have_css(".jt-qr__url", text: topic.relative_url)
      shot("qr-code")
      expect_no_theme_errors
    end

    it "shows when someone was last seen on their user card" do
      member.update!(last_seen_at: 2.hours.ago)
      sign_in(admin)
      visit(topic.relative_url)
      find("#post_1 .main-avatar[data-user-card='#{member.username}']").click
      expect(page).to have_css(".user-card .jt-last-seen")
      expect_no_theme_errors
    end

    it "shows the small logo on phones", mobile: true do
      SiteSetting.logo_small = Fabricate(:image_upload)
      visit("/latest")
      expect(page).to have_css("#site-logo.logo-mobile[src*='#{SiteSetting.logo_small.url}']")
    end

    it "keeps a mobile logo the admin uploaded", mobile: true do
      SiteSetting.logo_small = Fabricate(:image_upload)
      SiteSetting.mobile_logo = Fabricate(:image_upload)
      visit("/latest")
      expect(page).to have_css("#site-logo.logo-mobile[src*='#{SiteSetting.mobile_logo.url}']")
    end

    it "styles core's category boxes" do
      SiteSetting.desktop_category_page_style = "categories_boxes"
      visit("/categories")
      expect(page).to have_css(".category-boxes .category-box")
      shot("category-boxes")
      expect_no_theme_errors
    end
  end
end
