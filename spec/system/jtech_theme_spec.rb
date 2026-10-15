# frozen_string_literal: true

require "rails_helper"

# Installs the bundled JTech theme, makes it the default and walks the main
# pages on desktop and mobile. Fails when the theme throws, logs a theme error,
# trips a deprecation (system specs raise on those), or a JTech surface that
# should render doesn't. This is the CI guard for "a Discourse update broke the
# theme": CI runs against Discourse `latest`.
#
# Screenshots land in tmp/capybara/jtech_theme/ (uploaded by the Feature
# Screenshots workflow).
RSpec.describe "JTech theme" do
  fab!(:jtech_theme) do
    DiscourseJtechTheme::Installer.sync_now
    DiscourseJtechTheme::Installer.theme
  end
  fab!(:admin) { Fabricate(:admin, username: "jt_admin", name: "Jay Admin") }
  fab!(:member) do
    Fabricate(:user, username: "jt_member", name: "Morgan Member", trust_level: TrustLevel[2])
  end
  fab!(:category) { Fabricate(:category, name: "Filtering", description: "Filters and setups.") }
  fab!(:tag) { Fabricate(:tag, name: "android") }
  fab!(:topic) do
    Fabricate(
      :topic,
      category: category,
      user: member,
      tags: [tag],
      title: "Which filter works best on a flip phone?",
    )
  end
  fab!(:first_post) do
    Fabricate(
      :post,
      topic: topic,
      user: member,
      raw:
        "I'm setting up a flip phone and want something that blocks the browser.\n\n```ruby\nputs 1\n```\n\n[Read more](https://example.com/guide)",
    )
  end
  fab!(:replies) do
    Array.new(3) { |i| Fabricate(:post, topic: topic, user: admin, raw: "Reply number #{i + 1}.") }
  end
  fab!(:more_topics) do
    Array.new(4) do |i|
      t = Fabricate(:topic, category: category, user: admin, title: "Another useful topic #{i + 1}")
      Fabricate(:post, topic: t, user: admin, raw: "Body of topic #{i + 1}.")
      t
    end
  end

  before do
    SiteSetting.jtech_enabled = true
    # The row bounce is for the Default theme; here the JTech theme can be
    # theme 1, the setting's default, and its cards press on their own.
    SiteSetting.jtech_row_click_theme_ids = ""
    jtech_theme.set_default!
    DirectoryItem.refresh!
  end

  def shot(name)
    dir = Rails.root.join("tmp/capybara/jtech_theme")
    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}-#{is_mobile? ? "mobile" : "desktop"}.png").to_s)
  end

  # Theme errors are reported as "[THEME <id> 'JTech'] …" on the console and,
  # for admins, as a banner. Page errors (uncaught exceptions) count as well.
  def expect_no_theme_errors
    expect(page).to have_no_css(".broken-theme-alert-banner")
    errors =
      $playwright_logger.logs.select do |log|
        log[:level] == "error" &&
          (log[:source] == "pageerror-api" || log[:message].include?("THEME #{jtech_theme.id}"))
      end
    expect(errors.map { |e| e[:message] }).to eq([])
  end

  def visit_and_check(path, *selectors, name:)
    visit(path)
    expect(page).to have_css("#main-outlet")
    selectors.each { |selector| expect(page).to have_css(selector) }
    shot(name)
    expect_no_theme_errors
  end

  shared_examples "renders the main pages" do
    it "renders without theme errors" do
      sign_in(user) if user

      visit_and_check("/latest", ".jt-hero", ".jt-card", ".jt-footer", name: "#{role}-latest")
      visit_and_check("/categories", ".jt-footer", name: "#{role}-categories")
      visit_and_check(
        "/c/#{category.slug}/#{category.id}",
        ".jt-banner",
        ".jt-card",
        name: "#{role}-category",
      )
      visit_and_check("/tag/#{tag.name}", ".jt-banner", name: "#{role}-tag")
      visit_and_check(topic.relative_url, ".topic-post", name: "#{role}-topic")
      visit_and_check("/u", ".directory-table", name: "#{role}-users")
      visit_and_check("/u/#{member.username}/summary", ".user-main", name: "#{role}-profile")
      visit_and_check("/search?q=filter", ".search-container", name: "#{role}-search")
    end
  end

  context "when anonymous" do
    let(:user) { nil }
    let(:role) { "anon" }

    include_examples "renders the main pages"
    context "on mobile", mobile: true do
      include_examples "renders the main pages"
    end
  end

  context "when signed in" do
    let(:user) { member }
    let(:role) { "member" }

    include_examples "renders the main pages"
    context "on mobile", mobile: true do
      include_examples "renders the main pages"
    end
  end

  context "when signed in as an admin" do
    let(:user) { admin }
    let(:role) { "admin" }

    include_examples "renders the main pages"
  end

  # Core's about page: stats on a ruled strip, staff as avatar + name, the
  # right column as plain text. The theme: tiles, cards, one ruled card.
  it "shows the about page's counts as tiles, its staff as cards" do
    sign_in(member)
    visit("/about")
    # members and "created" always; admins / moderators only when core lists
    # someone, which it doesn't in this database
    expect(page).to have_css(".about__stats-item", minimum: 2)
    expect(page).to have_css(".about__right-side .about__activities-item")

    borders, tile_tops, staff_border = page.evaluate_script(<<~JS)
      [
        [".about__stats-item", ".about__right-side"]
          .map((selector) => getComputedStyle(document.querySelector(selector)).borderTopWidth),
        [...document.querySelectorAll(".about__stats-item")]
          .slice(0, 2)
          .map((tile) => Math.round(tile.getBoundingClientRect().top)),
        [...document.querySelectorAll(".about-page-users-list .user-info")]
          .map((card) => getComputedStyle(card).borderTopWidth),
      ]
    JS
    expect(borders).to eq(%w[1px 1px])
    expect(tile_tops[0]).to eq(tile_tops[1]) # a row of tiles, not a column
    expect(staff_border.uniq).to eq(["1px"]).or eq([]) # cards, when there are staff to show
    expect_no_theme_errors
  end

  describe "the avatar's menu" do
    it "opens on the profile tab, and the bell on notifications" do
      sign_in(member)
      visit("/latest")
      find("#toggle-current-user").click
      expect(page).to have_css("#user-menu-button-profile.active")

      find(".jt-header-notifications > .icon").click
      expect(page).to have_css("#user-menu-button-all-notifications.active")
      expect_no_theme_errors
    end

    it "opens on the review queue while the avatar's badge says something is waiting" do
      Fabricate(:reviewable)
      sign_in(admin)
      visit("/latest")
      expect(page).to have_css("#toggle-current-user .badge-notification.new-reviewables")
      find("#toggle-current-user").click
      expect(page).to have_css("#user-menu-button-review-queue.active")
      expect_no_theme_errors
    end
  end

  # Core's log in page: a bare form beside the other ways in. The theme puts
  # both on one card and makes the fields its own 44px controls.
  it "puts the log in page's form and other ways in on one card" do
    visit("/login")
    expect(page).to have_css(".login-fullpage #login-account-name")
    border, field_height = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".login-fullpage .login-body")).borderTopWidth,
        Math.round(document.querySelector("#login-account-name").getBoundingClientRect().height),
      ]
    JS
    expect(border).to eq("1px")
    expect(field_height).to eq(44)
    expect(page).to have_no_css(".jt-footer")
    expect_no_theme_errors
  end

  # A result's title or category, or what was typed, may be Hebrew in an
  # English menu (or the reverse): read in its own direction, it keeps its
  # punctuation at its end, and still lines up with the menu
  it "reads each command menu result in its own direction, lined up with the menu" do
    SiteSetting.chat_enabled = false # like the other command menu specs
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-search__keys")
    send_keys([:control, "k"])
    expect(page).to have_css(".jt-cmdk .jt-cmdk__item .jt-cmdk__label")
    label =
      page.evaluate_script(
        '[document.querySelector(".jt-cmdk__label").getAttribute("dir"), getComputedStyle(document.querySelector(".jt-cmdk__label")).textAlign]',
      )
    expect(label).to eq(%w[auto left])
  end

  # The theme's strings are English and the search field's and menu's end in
  # "…": read right to left in a Hebrew interface, the "…" came first
  # ("…Search"). They read left to right, still on the interface's side.
  it "keeps the search placeholders' … at their end in a Hebrew interface" do
    SiteSetting.chat_enabled = false # like the other command menu specs
    SiteSetting.default_locale = "he"
    sign_in(member)
    visit("/latest")
    expect(page).to have_css("html.rtl .jt-header-search__keys")
    send_keys([:control, "k"])
    expect(page).to have_css(".jt-cmdk .jt-cmdk__input")
    fields = page.evaluate_script(<<~JS)
      [".jt-header-search--centered .jt-header-search__label", ".jt-cmdk__input"].map((selector) => {
        const style = getComputedStyle(document.querySelector(selector));
        return [style.direction, style.textAlign];
      })
    JS
    expect(fields).to eq([%w[ltr right], %w[ltr right]])
    expect_no_theme_errors
  end

  # The menu's commands were the theme's own English words, so in Hebrew it
  # said "Latest", "Top"; where core has the same word it comes translated
  it "names the command menu's commands in the interface's language" do
    SiteSetting.chat_enabled = false # like the other command menu specs
    SiteSetting.default_locale = "he"
    sign_in(member)
    visit("/latest")
    expect(page).to have_css("html.rtl .jt-header-search__keys")
    send_keys([:control, "k"])
    expect(page).to have_css(
      ".jt-cmdk .jt-cmdk__label",
      text: I18n.t("js.keyboard_shortcuts_help.jump_to.latest", locale: :he),
    )
    expect(page).to have_no_css(".jt-cmdk .jt-cmdk__label", text: "Latest")
  end

  it "opens the command menu with Ctrl+K and finds a topic" do
    SiteSetting.chat_enabled = false
    SearchIndexer.enable
    SearchIndexer.index(topic, force: true)
    SearchIndexer.index(first_post, force: true)
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-search__keys")

    send_keys([:control, "k"])
    expect(page).to have_css(".jt-cmdk")
    shot("cmdk-open")

    find(".jt-cmdk__input").fill_in(with: "flip phone")
    expect(page).to have_css(".jt-cmdk__item", text: topic.title)
    shot("cmdk-results")
    expect_no_theme_errors

    send_keys(:escape)
    expect(page).to have_no_css(".jt-cmdk")
  end

  # The People page's six periods need about 350px in a row: at 360px "All
  # time" was cut off and only reachable by swiping
  it "shows every period on the People page on a 360px phone", mobile: true do
    sign_in(member)
    resize_window(width: 360) do
      visit("/u")
      expect(page).to have_css(".jt-seg .jt-seg__item", count: 6)
      hidden = page.evaluate_script(<<~JS)
        (() => {
          const periods = document.querySelector(".jt-seg");
          return periods.scrollWidth - periods.clientWidth;
        })()
      JS
      expect(hidden).to be <= 1
      expect_no_theme_errors
    end
  end

  # The period switch had the theme's own English words, so a Hebrew page
  # said "Week", "Month"; core's period words come translated
  it "labels the People page's periods in the interface's language" do
    SiteSetting.default_locale = "he"
    sign_in(member)
    visit("/u")
    expect(page).to have_css("html.rtl .jt-seg .jt-seg__item", count: 6)
    expect(page).to have_css(
      ".jt-seg .jt-seg__item",
      text: I18n.t("js.filters.top.this_week", locale: :he),
    )
    expect(page).to have_no_css(".jt-seg .jt-seg__item", text: "Week")
  end

  # Core's /badges: boxes with a faint border under grey group headings. The
  # theme: cards under small labels, and a badge's own page on its big card.
  it "shows badges as cards under group labels" do
    sign_in(member)
    visit("/badges")
    expect(page).to have_css(".badge-groups .badge-card .badge-link", minimum: 1)
    border, label_case = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".badge-card")).borderTopWidth,
        getComputedStyle(document.querySelector(".badge-grouping .title h2")).textTransform,
      ]
    JS
    expect(border).to eq("1px")
    expect(label_case).to eq("uppercase")

    find(".badge-card .badge-link", match: :first).click
    expect(page).to have_css(".show-badge .badge-card.--badge-large")
    expect_no_theme_errors
  end

  it "shows each command's keyboard shortcut, and binds the theme's own" do
    SiteSetting.chat_enabled = false
    sign_in(member)
    visit("/latest")
    send_keys([:control, "k"])
    expect(page).to have_css(".jt-cmdk__item", text: "Latest")
    keys = page.evaluate_script(<<~JS)
      Object.fromEntries(
        [...document.querySelectorAll(".jt-cmdk__item")].map((row) => [
          row.querySelector(".jt-cmdk__label").textContent.trim(),
          [...row.querySelectorAll(".jt-cmdk__keys kbd")].map((k) => k.textContent).join(" "),
        ])
      )
    JS
    expect(keys).to include(
      "Latest" => "g l",
      "Notifications" => "g i",
      "Preferences" => "g e",
      "Keyboard shortcuts" => "?",
    )
    shot("cmdk-shortcuts")

    send_keys(:escape)
    expect(page).to have_no_css(".jt-cmdk")
    send_keys("g", "i")
    expect(page).to have_current_path("/u/#{member.username}/notifications")
    expect_no_theme_errors
  end

  # With the Modern Category + Group Boxes component (installed with the theme
  # on the live forum) every span in a group card was big, bold and one clipped
  # line: the @handle looked like a second name, and at 320px (a Qin F21) a
  # long one made every card wider than the phone
  it "keeps group cards in a 320px phone with the group boxes component", mobile: true do
    Fabricate(:group, name: "filtering_specialist", full_name: "Filtering specialists")
    sign_in(member)
    resize_window(width: 320) do
      visit("/g")
      expect(page).to have_css(".groups-boxes .group-box .group-info-mention-name")
      # the component's rules for the card's insides, as it ships them
      page.execute_script(<<~JS)
        document.head.insertAdjacentHTML(
          "beforeend",
          `<style>
            .groups-boxes .group-box .group-box-inner { display: inline-grid; grid-auto-flow: row; }
            .groups-boxes .group-box .group-box-inner .group-info-wrapper .group-info {
              padding-right: 1em;
            }
            .groups-boxes .group-box .group-box-inner .group-info-wrapper .group-info span {
              font-size: 1.125em;
              font-weight: 600;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
          </style>`
        );
      JS
      page_width, window_width, handle_weight = page.evaluate_script(<<~JS)
        [
          document.documentElement.scrollWidth,
          document.documentElement.clientWidth,
          getComputedStyle(document.querySelector(".group-info-mention-name")).fontWeight,
        ]
      JS
      expect(page_width).to eq(window_width)
      expect(handle_weight).to eq("400")
      expect_no_theme_errors
    end
  end

  # Core's /g: boxes with a faint border under a loose row of filters, and a
  # group's members table bare. The theme: cards under a toolbar of equal
  # controls, and the users directory's table card for the members.
  # A grid item is as wide as its longest unbreakable word, so a long group
  # handle pushed every group card past a phone's edge.
  it "fits group cards with long handles on a phone", mobile: true do
    Fabricate(:group, name: "filtering_specialist", full_name: "Filteringspecialistsandhelpers")
    sign_in(member)
    visit("/g")
    expect(page).to have_css(".groups-boxes .group-box")
    widths = page.evaluate_script(<<~JS)
      ({ page: document.documentElement.scrollWidth, window: document.documentElement.clientWidth })
    JS
    expect(widths["page"]).to eq(widths["window"])
    expect_no_theme_errors
  end

  # On a 320px phone (a Qin F21's width) the footer's row didn't wrap: with
  # staff's extra button Reply ran off the screen and the page scrolled sideways
  it "wraps a topic's footer buttons on a narrow phone", mobile: true do
    sign_in(admin)
    resize_window(width: 320) do
      visit(topic.relative_url)
      reply = "#topic-footer-buttons .topic-footer-main-buttons > .create"
      expect(page).to have_css(reply)
      reply_right, window_width = page.evaluate_script(<<~JS)
        [
          document.querySelector("#{reply}").getBoundingClientRect().right,
          document.documentElement.clientWidth,
        ]
      JS
      expect(reply_right).to be <= window_width
      expect_no_theme_errors
    end
  end

  # "Skip to main content", the first Tab on a page, was core's square chip
  # jammed against the window's top edge, over the logo
  it "rounds the skip link and keeps it off the window's edge" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    find("body").send_keys(:tab)
    expect(page).to have_css(".skip-link:focus")
    sleep 0.3 # core slides it in from above
    radius, top =
      page.evaluate_script(
        "[getComputedStyle(document.activeElement).borderTopLeftRadius, document.activeElement.getBoundingClientRect().top]",
      )
    expect(radius).not_to eq("0px")
    expect(top).to be >= 4
    expect_no_theme_errors
  end

  # A dialog's body takes focus when the dialog opens (tabindex="-1"); after any
  # keyboard use the theme's focus ring framed the dialog's whole content
  it "draws no focus ring around a dialog's body" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    find("body").send_keys("?") # the keyboard opens it, so focus counts as keyboard focus
    expect(page).to have_css(".keyboard-shortcuts-modal .d-modal__body")
    ring = page.evaluate_script(<<~JS)
      (() => {
        const body = document.querySelector(".keyboard-shortcuts-modal .d-modal__body");
        body.focus();
        return [body.matches(":focus-visible"), getComputedStyle(body).outlineStyle];
      })()
    JS
    expect(ring).to eq([true, "none"])
    expect_no_theme_errors
  end

  # The composer's resize handle takes focus from the keyboard (the arrow keys
  # resize the composer), but it sits on the composer's clipped top edge: of
  # the outer ring only the bottom line showed
  it "draws the composer's resize handle's focus ring inside it" do
    sign_in(member)
    visit(topic.relative_url)
    find("#topic-footer-buttons .create").click
    expect(page).to have_css("#reply-control.open .grippie")
    find("#reply-control .d-editor-input").send_keys("x") # keyboard use, so focus counts as keyboard focus
    ring = page.evaluate_script(<<~JS)
      (() => {
        const grippie = document.querySelector("#reply-control .grippie");
        grippie.focus();
        const style = getComputedStyle(grippie);
        return [grippie.matches(":focus-visible"), style.outlineStyle, parseFloat(style.outlineOffset) < 0];
      })()
    JS
    expect(ring).to eq([true, "solid", true])
    expect_no_theme_errors
  end

  # A post's edit history: core underlined a revision's author and date with a
  # 3px grey bar, the only heavy line in the theme's dialogs
  it "draws the dialog's hairline under a revision in a post's history" do
    PostRevisor.new(first_post).revise!(
      member,
      { raw: "#{first_post.raw}\n\nEdited to add a line." },
      force_new_version: true,
    )
    sign_in(member)
    visit(topic.relative_url)
    find("#post_1 .post-info.edits .btn").click
    expect(page).to have_css(".history-modal #revision")
    revision, header = page.evaluate_script(<<~JS)
      [".history-modal #revision", ".history-modal .d-modal__header"].map((selector) => {
        const style = getComputedStyle(document.querySelector(selector));
        return [style.borderBottomWidth, style.borderBottomColor];
      })
    JS
    expect(revision).to eq(header)
    expect_no_theme_errors
  end

  # Core fits the history's buttons on one row by cutting their labels short
  # (on a phone they read "Edit …", "Revert to rev…" and "Hide rev…"), and at
  # 320px its arrows between revisions ran past the sheet's padding
  it "fits a post's history's buttons and arrows on a 320px phone" do
    PostRevisor.new(first_post).revise!(
      admin,
      { raw: "#{first_post.raw}\n\nEdited to add a line." },
      force_new_version: true,
    )
    sign_in(admin)
    resize_window(width: 320) do
      visit(topic.relative_url)
      find("#post_1 .post-info.edits .btn").click
      expect(page).to have_css(".history-modal #revision-footer-buttons .btn", minimum: 3)
      cut, arrows_overflow = page.evaluate_script(<<~JS)
        [
          [...document.querySelectorAll(".history-modal #revision-footer-buttons .d-button-label")]
            .filter((label) => label.scrollWidth > label.clientWidth)
            .map((label) => label.textContent.trim()),
          document.querySelector(".history-modal #revision-controls").scrollWidth -
            document.querySelector(".history-modal #revision-controls").clientWidth,
        ]
      JS
      expect(cut).to eq([])
      expect(arrows_overflow).to be <= 0
    end
    expect_no_theme_errors
  end

  # The search page's Posts / Categories & tags / Users tabs are buttons, not
  # links: they missed the tabs' weight and their inner focus ring, so the row
  # (which scrolls, and clips) cut the ring's top and bottom off
  it "gives the search page's tabs the tabs' weight and an inner focus ring" do
    sign_in(member)
    visit("/search?q=filter")
    expect(page).to have_css(".nav-pills.search-types button.search-types__type", minimum: 2)
    find("body").send_keys(:tab) # keyboard use, so focus counts as keyboard focus
    tab = page.evaluate_script(<<~JS)
      (() => {
        const tab = document.querySelector(".nav-pills button.search-types__type:not(.active)");
        tab.focus();
        const style = getComputedStyle(tab);
        return [tab.matches(":focus-visible"), parseFloat(style.outlineOffset) < 0, style.fontWeight];
      })()
    JS
    expect(tab).to eq([true, true, "500"])
    expect_no_theme_errors
  end

  # Core turns the outline off on buttons (.btn:focus-visible, and on desktop
  # .discourse-no-touch nav.post-controls .actions button:focus-visible) and
  # marks focus with the hover fill, which the theme's quiet buttons barely
  # have: keyboard focus vanished on most of them.
  it "rings a button that has keyboard focus, inside the post menu too" do
    sign_in(member)
    visit("/t/#{topic.slug}/#{topic.id}")
    expect(page).to have_css("#post_1 nav.post-controls .actions button.reply")
    send_keys(:tab) # keyboard first, so the focus() calls below count as keyboard focus
    rings = page.evaluate_script(<<~JS)
      ["#toggle-current-user", "#post_1 nav.post-controls .actions button.reply"].map((selector) => {
        const button = document.querySelector(selector);
        button.focus();
        const style = getComputedStyle(button);
        return [
          button.matches(":focus-visible"),
          style.outlineStyle,
          Math.sign(parseFloat(style.outlineOffset)),
        ];
      })
    JS
    expect(rings[0]).to eq([true, "solid", 1])
    # the post menu scrolls sideways, so the ring is drawn inside the button
    expect(rings[1]).to eq([true, "solid", -1])
    expect_no_theme_errors
  end

  # Core renders the location / website line and the bio even for someone who
  # has neither: in the theme's column of lines under the name each took a
  # gap, blank space under the name on most profiles
  it "leaves no blank lines under a profile's name" do
    # someone else's profile: on your own, core collapses the header and leaves
    # the bio out
    sign_in(admin)
    blank = <<~JS
      [...document.querySelector(".user-main .primary-textual").children]
        .filter((line) => getComputedStyle(line).display !== "none")
        .filter((line) => line.getBoundingClientRect().height === 0)
        .map((line) => line.className || line.tagName)
    JS
    visit("/u/#{member.username}/summary")
    expect(page).to have_css(".user-main .primary-textual .user-profile-names")
    expect(page.evaluate_script(blank)).to eq([])

    member.user_profile.update!(bio_raw: "I set up flip phones.")
    visit("/u/#{member.username}/summary")
    expect(page).to have_css(".user-main .primary-textual .bio", text: "I set up flip phones.")
    expect(page.evaluate_script(blank)).to eq([])
    expect_no_theme_errors
  end

  # On a profile core makes a <button> 1rem, which outranked the theme's button
  # size, so a link styled as a button (Admin), the notification-level
  # dropdown and REQ-PM came out a size smaller and 2px shorter. On every tab
  # but the summary core's translucent fill also put a darker box in the card.
  it "gives a profile's controls one size, and no box behind the compact header" do
    sign_in(admin)
    visit("/u/#{member.username}/summary")
    expect(page).to have_css(".user-main .controls .user-admin")
    expect(page).to have_css(".user-main .controls .user-notifications-dropdown")
    sizes = page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".user-main .controls :is(.btn, .select-kit-header)")]
        .filter((control) => control.getBoundingClientRect().width > 0)
        .map((control) => [
          getComputedStyle(control).fontSize,
          Math.round(control.getBoundingClientRect().height),
        ])
    JS
    expect(sizes.uniq.size).to eq(1)

    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    visit("/u/#{member.username}/activity")
    expect(page).to have_css(".user-main .about.collapsed-info .details")
    fill = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".user-main .about.collapsed-info .details"))
        .backgroundColor
    JS
    expect(fill).to eq("rgba(0, 0, 0, 0)")
    expect_no_theme_errors
  end

  # A plugin's outlet with nothing to show (Follow, on your own profile) left
  # an empty <li> at the start of a profile's row of buttons; it took a gap,
  # so the first button sat 8px in from the ones on the line under it
  it "lines a profile's buttons up when the row starts with an empty outlet" do
    sign_in(member)
    visit("/u/#{member.username}/summary")
    expect(page).to have_css(".user-main .controls ul > li .btn")
    offset = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(".user-main .controls ul");
        row.prepend(document.createElement("li"));
        const button = row.querySelector("li .btn");
        return Math.round(button.getBoundingClientRect().left - row.getBoundingClientRect().left);
      })()
    JS
    expect(offset).to eq(0)
    expect_no_theme_errors
  end

  # The compact header (every profile tab but the summary) has no stats strip
  # under the details, but kept core's line between them: a stray rule under
  # the buttons, above the card's bottom edge
  it "draws no line under the compact profile header's buttons" do
    sign_in(member)
    visit("/u/#{member.username}/activity")
    expect(page).to have_css(".user-main .about.collapsed-info .details")
    line =
      page.evaluate_script(
        'getComputedStyle(document.querySelector(".user-main .about.collapsed-info .details")).borderBottomWidth',
      )
    expect(line).to eq("0px")
    expect_no_theme_errors
  end

  it "shows groups as cards, and a group's members in the directory's table card" do
    sign_in(admin)
    visit("/g")
    expect(page).to have_css(".groups-boxes .group-box", minimum: 2)
    box_border, filter_height = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".group-box")).borderTopWidth,
        Math.round(document.querySelector(".groups-header-filters-name").getBoundingClientRect().height),
      ]
    JS
    expect(box_border).to eq("1px")
    expect(filter_height).to eq(38) # 2.4rem, like the other controls

    visit("/g/staff")
    expect(page).to have_css(".group-members .directory-table__row", text: admin.username)
    card_border = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".container.group .horizontal-scroll-sync__content")).borderTopWidth
    JS
    expect(card_border).to eq("1px")
    expect_no_theme_errors
  end

  # On phones the command menu showed keyboard hints beside its tap targets:
  # an "esc" keycap next to the x (the keycap rule outweighed the touch one)
  # and a return-key glyph on the active row.
  it "drops the command menu's keyboard hints on phones", mobile: true do
    SiteSetting.chat_enabled = false
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    find(".jt-header-search__button").click
    expect(page).to have_css(".jt-cmdk .jt-cmdk__item.--active")
    hints = page.evaluate_script(<<~JS)
      (() => {
        const close = document.querySelector(".jt-cmdk__esc");
        const shown = (el) => getComputedStyle(el).display !== "none";
        return {
          esc: shown(close.querySelector("kbd")),
          x: shown(close.querySelector(".d-icon")),
          enter: shown(document.querySelector(".jt-cmdk__item.--active .jt-cmdk__enter")),
        };
      })()
    JS
    expect(hints).to eq("esc" => false, "x" => true, "enter" => false)
    expect_no_theme_errors
  end

  # On phones core makes a dialog a fixed sheet with no left or right, so the
  # command menu, narrower than the screen, sat against the left edge
  it "centres the command menu on a phone", mobile: true do
    SiteSetting.chat_enabled = false
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    find(".jt-header-search__button").click
    expect(page).to have_css(".jt-cmdk .d-modal__container")
    left, right = page.evaluate_script(<<~JS)
      (() => {
        const menu = document.querySelector(".jt-cmdk .d-modal__container").getBoundingClientRect();
        return [menu.left, document.documentElement.clientWidth - menu.right];
      })()
    JS
    expect(left).to be > 0
    expect(left).to be_within(1).of(right)
    expect_no_theme_errors
  end

  # On a 320px phone (a Qin F21) a result's category took up to 40% of its row
  # and titles were cut to "How to Write th…"; it goes under the title
  it "puts a command menu result's category under its title on a narrow phone", mobile: true do
    SiteSetting.chat_enabled = false
    SearchIndexer.enable
    SearchIndexer.index(topic, force: true)
    SearchIndexer.index(first_post, force: true)
    sign_in(member)
    resize_window(width: 320) do
      visit("/latest")
      expect(page).to have_css(".jt-card")
      find(".jt-header-search__button").click
      find(".jt-cmdk__input").fill_in(with: "flip phone")
      expect(page).to have_css(".jt-cmdk__item .jt-cmdk__hint")
      below = page.evaluate_script(<<~JS)
        (() => {
          const item = document.querySelector(".jt-cmdk__item:has(.jt-cmdk__hint)");
          const title = item.querySelector(".jt-cmdk__label").getBoundingClientRect();
          return item.querySelector(".jt-cmdk__hint").getBoundingClientRect().top >= title.bottom - 1;
        })()
      JS
      expect(below).to eq(true)
      expect_no_theme_errors
    end
  end

  it "leaves Ctrl+K to chat for people who can chat" do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-search__button")
    expect(page).to have_no_css(".jt-header-search__keys")

    find(".jt-header-search__button").click
    expect(page).to have_css(".jt-cmdk")
    expect_no_theme_errors
  end

  # Core's text-only empty states are a heading and a paragraph at the top
  # left of a blank page; the theme puts them on a centred card with a glyph.
  # Core's error page was ":(" in huge type over the reason; the theme draws
  # it as the empty states' card with a glyph chip. Reached the way core's own
  # spec does: a hidden profile, visited logged out.
  it "shows the error page on the empty states' card" do
    SiteSetting.hide_user_profiles_from_public = true
    visit("/u/#{member.username}")
    expect(page).to have_css(".error-page .reason")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const card = getComputedStyle(document.querySelector(".error-page"));
        const face = document.querySelector(".error-page .face");
        return {
          card: card.borderTopWidth,
          face: getComputedStyle(face).fontSize,
          glyph: getComputedStyle(face, "::after").content,
        };
      })()
    JS
    expect(looks).to eq("card" => "1px", "face" => "0px", "glyph" => '""')
    shot("error-page")
    expect_no_theme_errors
  end

  it "shows an empty page's message on a centred card" do
    sign_in(member)
    visit("/u/#{member.username}/activity/bookmarks")
    expect(page).to have_css(".empty-state__container.--text-only .empty-state__title")
    border, centred = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".empty-state__container.--text-only");
        const outlet = document.querySelector("#main-outlet").getBoundingClientRect();
        const r = card.getBoundingClientRect();
        return [
          getComputedStyle(card).borderTopWidth,
          Math.abs((r.left - outlet.left) - (outlet.right - r.right)) <= 1,
        ];
      })()
    JS
    expect(border).to eq("1px")
    expect(centred).to eq(true)
    expect_no_theme_errors
  end

  it "centres the search field on the header bar on wide screens" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-search--centered .jt-header-search__button")
    expect(page).to have_no_css(".d-header-icons .jt-header-search__button")
    bar_centre, field_centre = page.evaluate_script(<<~JS)
      [".d-header > .wrap > .contents", ".jt-header-search--centered .jt-header-search__button"]
        .map((selector) => document.querySelector(selector).getBoundingClientRect())
        .map((r) => r.left + r.width / 2)
    JS
    expect(field_centre).to be_within(1).of(bar_centre)
    expect_no_theme_errors
  end

  # Core's notifications page: a bare list under two filters; unread type
  # badges in the accent colour. The theme: a toolbar, a card, black / white.
  it "lists notifications on a card, with unread type badges in the text colour" do
    Fabricate(
      :notification,
      user: member,
      topic: topic,
      post_number: first_post.post_number,
      notification_type: Notification.types[:mentioned],
      read: false,
      data: {
        topic_title: topic.title,
        original_post_id: first_post.id,
        original_username: admin.username,
        display_username: admin.username,
      }.to_json,
    )
    SiteSetting.show_user_menu_avatars = true # the badge sits on the avatar
    sign_in(member)
    visit("/u/#{member.username}/notifications")
    expect(page).to have_css(
      ".user-notifications-list li.notification.unread .icon-avatar__icon-wrapper",
    )

    card_border, filter_height, badge_bg, label_color = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(".user-notifications-list li.notification.unread");
        return [
          getComputedStyle(document.querySelector(".user-notifications-list")).borderTopWidth,
          Math.round(document.querySelector(".user-notifications-filter .select-kit-header").getBoundingClientRect().height),
          getComputedStyle(row.querySelector(".icon-avatar__icon-wrapper")).backgroundColor,
          getComputedStyle(row.querySelector(".item-label")).color,
        ];
      })()
    JS
    expect(card_border).to eq("1px")
    expect(filter_height).to eq(35) # 2.2rem, like the other toolbars
    expect(badge_bg).to eq(label_color) # JTech Light's accent is its text colour
    expect_no_theme_errors
  end

  # Core opens each review item with a bar in the inverted text colour (solid
  # black, or white in dark mode) and says "no items" in bare text; the
  # avatar's review badge is red. The theme: a quiet title row, an outlined
  # Pending, the empty-page card, and the header's inverse pill.
  it "keeps the review queue in the theme's quiet cards" do
    Fabricate(:reviewable_flagged_post, topic: topic, target: first_post)
    sign_in(admin)
    visit("/latest")
    expect(page).to have_css(".d-header .badge-notification.new-reviewables")
    badge = page.evaluate_script(<<~JS)
      (() => {
        const badge = getComputedStyle(document.querySelector(".d-header .new-reviewables"));
        return badge.backgroundColor === getComputedStyle(document.body).color;
      })()
    JS
    expect(badge).to eq(true)

    visit("/review")
    expect(page).to have_css(".review-item__header")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const header = getComputedStyle(document.querySelector(".review-item__header"));
        const pending = getComputedStyle(document.querySelector(".review-item__status.--pending"));
        const text = getComputedStyle(document.body).color;
        return {
          headerInText: header.color === text,
          headerFilled: header.backgroundColor === text,
          pending: pending.backgroundColor,
        };
      })()
    JS
    expect(looks).to eq(
      "headerInText" => true,
      "headerFilled" => false,
      "pending" => "rgba(0, 0, 0, 0)",
    )
    shot("review-queue")

    visit("/review?type=ReviewableUser")
    expect(page).to have_css(".reviewable-list .no-review")
    empty =
      page.evaluate_script(
        "getComputedStyle(document.querySelector('.reviewable-list .no-review')).borderTopWidth",
      )
    expect(empty).to eq("1px")
    expect_no_theme_errors
  end

  # The hero's copy is admin-written, usually English. In a Hebrew interface it
  # took the page's direction, so a sentence's full stop landed at its start;
  # it reads in its own direction now, still aligned to the interface's side
  it "reads the hero's English copy left to right in a Hebrew interface, aligned right" do
    SiteSetting.default_locale = "he"
    visit("/latest")
    expect(page).to have_css("html.rtl .jt-hero__subtitle")
    subtitle =
      page.evaluate_script(
        '(() => { const s = getComputedStyle(document.querySelector(".jt-hero__subtitle")); return [s.direction, s.textAlign]; })()',
      )
    expect(subtitle).to eq(%w[ltr right])
    expect_no_theme_errors
  end

  # So does the search field's placeholder: on a phone it's wider than the
  # field, which cut off its start ("h phones, filters, guides"). It ends in
  # "…" instead.
  it "starts the hero search's English placeholder at its start in a Hebrew interface",
     mobile: true do
    SiteSetting.default_locale = "he"
    resize_window(width: 375) do
      visit("/latest")
      expect(page).to have_css("html.rtl .jt-hero__input")
      input =
        page.evaluate_script(
          '(() => { const s = getComputedStyle(document.querySelector(".jt-hero__input")); return [s.direction, s.textAlign, s.textOverflow]; })()',
        )
      expect(input).to eq(%w[ltr right ellipsis])
      expect_no_theme_errors
    end
  end

  # The room kept clear of the close button ran down the whole column, so on
  # a phone the search field stopped 40px short of the card's edge
  it "keeps the hero's search field the card's full width on a phone", mobile: true do
    resize_window(width: 375) do
      visit("/latest")
      expect(page).to have_css(".jt-hero__close")
      edges = page.evaluate_script(<<~JS)
        (() => {
          const hero = document.querySelector(".jt-hero");
          const style = getComputedStyle(hero);
          const box = hero.getBoundingClientRect();
          const inset = (side) =>
            parseFloat(style[`padding${side}`]) + parseFloat(style[`border${side}Width`]);
          const search = document.querySelector(".jt-hero__search").getBoundingClientRect();
          return [
            [Math.round(box.left + inset("Left")), Math.round(box.right - inset("Right"))],
            [Math.round(search.left), Math.round(search.right)],
          ];
        })()
      JS
      expect(edges[1]).to eq(edges[0])
      expect_no_theme_errors
    end
  end

  # The planet sits opposite the headline: on the left in a Hebrew interface,
  # where the headline is on the right
  it "puts the hero's planet opposite the headline in a Hebrew interface" do
    SiteSetting.default_locale = "he"
    visit("/latest")
    expect(page).to have_css("html.rtl .jt-hero__planet canvas")
    sides = page.evaluate_script(<<~JS)
      (() => {
        const centre = (selector) => {
          const box = document.querySelector(selector).getBoundingClientRect();
          return box.left + box.width / 2;
        };
        const hero = centre(".jt-hero");
        return [centre(".jt-hero__planet") < hero, centre(".jt-hero__title") > hero];
      })()
    JS
    expect(sides).to eq([true, true])
    expect_no_theme_errors
  end

  # The planet turns while it's on screen, stays still for people who ask
  # for reduced motion, and an admin can leave it out
  it "turns the hero's planet, holds it still for reduced motion, and can leave it out" do
    visit("/latest")
    expect(page).to have_css(".jt-hero__planet[data-jt-planet='running']")
    # the dots fade in as the hero arrives
    drawn = <<~JS
      (() => {
        const canvas = document.querySelector('.jt-hero__planet canvas[data-layer="dots"]');
        const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height);
        return pixels.data.some((value, i) => i % 4 === 3 && value > 0);
      })()
    JS
    try_until_success { expect(page.evaluate_script(drawn)).to eq(true) }

    page.driver.with_playwright_page { |pw| pw.emulate_media(reducedMotion: "reduce") }
    visit("/latest")
    expect(page).to have_css(".jt-hero__planet[data-jt-planet='still']")

    jtech_theme.update_setting(:hero_planet, false)
    jtech_theme.save!
    visit("/latest")
    expect(page).to have_css(".jt-hero__title")
    expect(page).to have_no_css(".jt-hero__planet")
    expect_no_theme_errors
  end

  # Scrolled out of sight, the hero's endless animations (the meteor, the
  # stars' twinkle, the headline's light) hold still, and carry on when it's
  # back
  it "pauses the hero's animations while it's scrolled out of sight" do
    visit("/latest")
    expect(page).to have_css(".jt-hero__meteor", visible: :all) # see-through between passes
    play_state = "getComputedStyle(document.querySelector('.jt-hero__meteor')).animationPlayState"
    expect(page.evaluate_script(play_state)).to eq("running")

    page.execute_script(<<~JS)
      document.querySelector("#main-outlet").style.paddingBottom = "300vh";
      window.scrollTo(0, document.documentElement.scrollHeight);
    JS
    expect(page).to have_css(".jt-hero[data-jt-away]")
    expect(page.evaluate_script(play_state)).to eq("paused")

    page.execute_script("window.scrollTo(0, 0)")
    expect(page).to have_no_css(".jt-hero[data-jt-away]")
    expect(page.evaluate_script(play_state)).to eq("running")
    expect_no_theme_errors
  end

  # Visitors get a way in under the search, in core's own (translated) words;
  # with sign-ups closed only Log In, as the main button; members get neither
  it "offers visitors a way in from the hero" do
    visit("/latest")
    expect(page).to have_css(".jt-hero__actions .jt-hero__sign-up.btn-primary", text: "Sign Up")
    expect(page).to have_css(".jt-hero__actions .jt-hero__log-in.btn-default", text: "Log In")

    SiteSetting.invite_only = true
    visit("/latest")
    expect(page).to have_css(".jt-hero__actions .jt-hero__log-in.btn-primary")
    expect(page).to have_no_css(".jt-hero__sign-up")

    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-hero__title")
    expect(page).to have_no_css(".jt-hero__actions")
    expect_no_theme_errors
  end

  # The hero arrives (its entrance) the first time in a tab, not on every
  # visit to the front page
  it "plays the hero's entrance once in a tab" do
    visit("/latest")
    expect(page).to have_css(".jt-hero")
    expect(page).to have_css(".jt-hero.--enter", wait: 0)

    visit("/latest")
    expect(page).to have_css(".jt-hero")
    expect(page).to have_no_css(".jt-hero.--enter", wait: 0)
  end

  # While the search has focus the planet brightens and the rest steps back
  it "lights the hero up while its search has focus" do
    visit("/latest")
    find(".jt-hero__input").click
    expect(page).to have_css(".jt-hero.--searching")
    find(".jt-hero__title").click
    expect(page).to have_no_css(".jt-hero.--searching")
  end

  # Closed, the hero folds away (the planet flying off), and it stays closed
  # on the next visit
  it "folds the hero away when it's closed, and keeps it closed" do
    visit("/latest")
    find(".jt-hero__close").click
    expect(page).to have_no_css(".jt-hero")

    visit("/latest")
    expect(page).to have_css("#navigation-bar")
    expect(page).to have_no_css(".jt-hero")
  end

  # Hidden touches: the planet turns by hand (held while it's dragged, and
  # the click that ends a drag sends nothing), a tap on the empty sky sends
  # a shooting star, and the Konami code a shower of them
  it "lets the hero's planet be turned by hand and its sky be played with" do
    visit("/latest")
    expect(page).to have_css(".jt-hero__planet[data-jt-planet='running']")
    globe = page.evaluate_script(<<~JS)
      (() => {
        const planet = document.querySelector(".jt-hero__planet");
        const box = planet.getBoundingClientRect();
        const style = getComputedStyle(planet);
        const at = (name) => parseFloat(style.getPropertyValue(name)) * box.width;
        return [box.left + at("--jt-planet-x"), box.top + at("--jt-planet-y")];
      })()
    JS
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(globe[0], globe[1])
      pw.mouse.down
      pw.mouse.move(globe[0] + 60, globe[1], steps: 6)
    end
    expect(page).to have_css(".jt-hero.--grabbing")
    page.driver.with_playwright_page { |pw| pw.mouse.up }
    expect(page).to have_no_css(".jt-hero.--grabbing")
    expect(page).to have_no_css(".jt-hero__shoot")

    corner =
      page.evaluate_script(
        "(() => { const box = document.querySelector('.jt-hero').getBoundingClientRect(); return [box.left + 12, box.bottom - 12]; })()",
      )
    page.driver.with_playwright_page { |pw| pw.mouse.click(corner[0], corner[1]) }
    expect(page).to have_css(".jt-hero__shoot")

    find("body").send_keys(:up, :up, :down, :down, :left, :right, :left, :right, "b", "a")
    expect(page).to have_css(".jt-hero__shoot", minimum: 5)
    expect_no_theme_errors
  end

  # Windows high contrast: no planet, stars or moving light; a plain border
  it "leaves the hero's planet and light out of high contrast mode" do
    page.driver.with_playwright_page { |pw| pw.emulate_media(forcedColors: "active") }
    visit("/latest")
    expect(page).to have_css(".jt-hero__title")
    hidden =
      page.evaluate_script(
        '[".jt-hero__sky", ".jt-hero__edge"].map((s) => getComputedStyle(document.querySelector(s)).display)',
      )
    expect(hidden).to eq(%w[none none])
  end

  # On a 320px phone (a Qin F21) the headline, search and buttons all fit
  # inside the card
  it "fits the hero's copy on a 320px phone", mobile: true do
    resize_window(width: 320) do
      visit("/latest")
      expect(page).to have_css(".jt-hero__actions")
      over = page.evaluate_script(<<~JS)
        (() => {
          const edge = document.querySelector(".jt-hero__copy").getBoundingClientRect().right;
          return [...document.querySelectorAll(".jt-hero__copy > *, .jt-hero__actions > *")]
            .filter((element) => element.getBoundingClientRect().right > edge + 1)
            .map((element) => element.className);
        })()
      JS
      expect(over).to eq([])
      expect_no_theme_errors
    end
  end

  # Who's Online marks a row whose last poster is online and its phone rule
  # lit every avatar in it, so a card's whole stack glowed. CI doesn't install
  # the plugin: its classes are set here as it sets them.
  it "marks only the last poster's face on a card when they're online", mobile: true do
    # as posting does: the replier is the last poster, beside the author
    topic.update!(last_post_user_id: admin.id)
    TopicFeaturedUsers.ensure_consistency!(topic.id)
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card .jt-card__people img.avatar", minimum: 2)
    shadows = page.evaluate_script(<<~JS)
      (() => {
        document.documentElement.classList.add("whos-online-glow");
        // the plugin's own phone rule, which rings every avatar in the row
        document.head.insertAdjacentHTML(
          "beforeend",
          "<style>html.whos-online-glow.mobile-view .topic-list-item.last-poster-online img.avatar { box-shadow: 0 0 4px 1px green; }</style>"
        );
        const row = [...document.querySelectorAll(".topic-list-item")].find(
          (r) => r.querySelectorAll(".jt-card__people img.avatar").length > 1
        );
        row.classList.add("last-poster-online");
        return [...row.querySelectorAll(".jt-card__people img.avatar")].map((img) => [
          img.classList.contains("latest"),
          getComputedStyle(img).boxShadow !== "none",
        ]);
      })()
    JS
    expect(shadows.count { |last, _| last }).to eq(1)
    expect(shadows).to all(satisfy { |last, ringed| last == ringed })
    expect_no_theme_errors
  end

  # Discourse's Compact Nav: the tabs are one dropdown on a computer too
  it "shows the list's tabs as one dropdown" do
    sign_in(member)
    visit("/latest")
    find(".list-control-toggle-link-trigger").click
    find(".list-control-toggle-link-content .nav-item_new a").click
    expect(page).to have_current_path("/new")
    expect(page).to have_css(".list-control-toggle-link-trigger", text: "New")
    expect_no_theme_errors
  end

  it "moves the filters up a line rather than parting the tabs from New Topic" do
    Fabricate(:category, name: "Filter apps", parent_category: category)
    sign_in(admin)
    resize_window(width: 900) do
      visit(category.url)
      expect(page).to have_css(".list-controls #create-topic")
      filters, tabs, new_topic, scrolls_sideways = page.evaluate_script(<<~JS)
        [".category-breadcrumb", "#navigation-bar", "#create-topic"]
          .map((s) => document.querySelector(`.list-controls ${s}`).getBoundingClientRect())
          .map((box) => Math.round(box.top + box.height / 2))
          .concat(document.documentElement.scrollWidth > window.innerWidth)
      JS
      expect(filters).to be < tabs
      expect(new_topic).to be_within(2).of(tabs)
      expect(scrolls_sideways).to eq(false)
      expect_no_theme_errors
    end
  end

  # Packed to the left: with the filters pushed left too, the dropdown floated
  # in the middle of the row
  it "puts the tabs' dropdown beside the filters" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".list-controls .list-control-toggle-link-trigger")
    gap = page.evaluate_script(<<~JS)
      document.querySelector(".list-controls #navigation-bar").getBoundingClientRect().left -
        document.querySelector(".list-controls .category-breadcrumb").getBoundingClientRect().right
    JS
    expect(gap).to be_between(0, 24)
    expect_no_theme_errors
  end

  # Core fills highlighted text with the palette's highlight colour, a mid
  # grey here: black text on #666 in light (3.7:1); in dark the browser's own
  # black text on a light grey slab
  it "highlights text with a soft band, the text in its usual colour" do
    post = Fabricate(:post, topic: topic, user: admin, raw: "Read <mark>this part</mark> twice.")
    highlight = <<~JS
      (() => {
        const mark = document.querySelector("#post_#{post.post_number} .cooked mark");
        const canvas = Object.assign(document.createElement("canvas"), { width: 1, height: 1 });
        const ctx = canvas.getContext("2d");
        const paint = (...colors) => {
          for (const color of colors) {
            ctx.fillStyle = color;
            ctx.fillRect(0, 0, 1, 1);
          }
          return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3);
        };
        const lum = ([r, g, b]) => {
          const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
        };
        const page = getComputedStyle(document.body).backgroundColor;
        const text = paint(getComputedStyle(mark).color);
        const band = paint(page, getComputedStyle(mark).backgroundColor);
        const [hi, lo] = [lum(text), lum(band)].sort((a, b) => b - a);
        return {
          usual_colour: text.join() === paint(getComputedStyle(mark.parentElement).color).join(),
          readable: (hi + 0.05) / (lo + 0.05) >= 4.5,
          visible: band.join() !== paint(page).join(),
        };
      })()
    JS
    expected = { "usual_colour" => true, "readable" => true, "visible" => true }

    sign_in(member)
    visit(post.url)
    expect(page).to have_css("#post_#{post.post_number} .cooked mark")
    expect(page.evaluate_script(highlight)).to eq(expected)

    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    visit(post.url)
    expect(page).to have_css("#post_#{post.post_number} .cooked mark")
    expect(page.evaluate_script(highlight)).to eq(expected)
    expect_no_theme_errors
  end

  # Core draws a quote's expand chevron and jump arrow in a pale grey (1.5:1 on
  # the card), and the arrow, a link, smaller than the chevron, a button
  it "draws a quote's controls at one size in a readable grey" do
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        raw:
          "[quote=\"#{member.username}, post:1, topic:#{topic.id}\"]\nI'm setting up a flip phone.\n[/quote]",
      )
    sign_in(member)
    visit("#{topic.relative_url}/#{post.post_number}")
    controls = "#post_#{post.post_number} aside.quote .quote-controls"
    expect(page).to have_css("#{controls} .quote-toggle")
    expect(page).to have_css("#{controls} .back")
    icons = page.evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("div");
        probe.style.color = "var(--jt-text-subtle)";
        document.body.appendChild(probe);
        const subtle = getComputedStyle(probe).color;
        probe.remove();
        return [...document.querySelectorAll("#{controls} .d-icon")].map((icon) => [
          Math.round(icon.getBoundingClientRect().width),
          getComputedStyle(icon).color === subtle,
        ]);
      })()
    JS
    expect(icons.size).to eq(2)
    expect(icons.uniq.size).to eq(1)
    expect(icons.first.last).to eq(true)
    expect_no_theme_errors
  end

  # Core's [details] is a grey bar with ► / ▼, a quote a grey title bar over a
  # barred blockquote, a onebox a 1px + 4px ring. The theme: one hairline card
  # for each, the section's chevron turning when it opens.
  # The composer's rich editor (core's default) drew [details] as a grey bar
  # with a triangle and a blockquote as a grey box; in the post both are the
  # theme's (jt-post-blocks). Now the editor shows them as the post will.
  it "draws sections and blockquotes in the rich editor as they'll look in the post" do
    # tests start in Markdown; core's rich editor specs set the mode the same way
    member.user_option.update!(composition_mode: UserOption.composition_mode_types[:rich])
    sign_in(member)
    visit(topic.relative_url)
    find(".topic-footer-main-buttons .create").click
    composer = PageObjects::Components::Composer.new
    expect(composer).to be_opened
    expect(page).to have_css("#reply-control .ProseMirror")
    composer.toggle_rich_editor
    composer.fill_content("[details=\"Steps\"]\nHold power.\n[/details]\n\n> A plain blockquote")
    composer.toggle_rich_editor
    expect(page).to have_css("#reply-control .ProseMirror details summary")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const editor = document.querySelector("#reply-control .ProseMirror");
        const details = editor.querySelector("details");
        const quote = editor.querySelector(":scope > blockquote");
        return {
          details: getComputedStyle(details).borderTopWidth,
          marker: getComputedStyle(details.querySelector("summary"), "::before").content,
          bar: getComputedStyle(quote).borderLeftWidth,
          fill: getComputedStyle(quote).backgroundColor,
        };
      })()
    JS
    expect(looks).to eq(
      "details" => "1px",
      "marker" => '""',
      "bar" => "2px",
      "fill" => "rgba(0, 0, 0, 0)",
    )
    expect_no_theme_errors
  end

  # In a Hebrew interface core's right-to-left stylesheet negated the open
  # section's rotate(90deg), so its chevron pointed up; and a right-to-left
  # section's chevron pointed away from its text
  it "turns a section's chevron down when it opens, in either direction" do
    SiteSetting.support_mixed_text_direction = true # each section in its own direction
    SiteSetting.default_locale = "he"
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        raw:
          "[details=\"Steps\"]\nHold power.\n[/details]\n\n[details=\"שלבים\"]\nתוכן\n[/details]",
      )
    visit(post.url)
    expect(page).to have_css("html.rtl #post_#{post.post_number} .cooked details summary", count: 2)
    chevrons = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("#post_#{post.post_number} .cooked details")].map((details) => {
        const closed = getComputedStyle(details.querySelector("summary"), "::before").scale;
        details.open = true;
        const open = getComputedStyle(details.querySelector("summary"), "::before");
        return [closed, open.rotate, open.transform];
      })
    JS
    # an English section, then a Hebrew one (right to left, like the page)
    expect(chevrons).to eq([%w[none 90deg none], ["-1 1", "-90deg", "none"]])
    expect_no_theme_errors
  end

  # A Hebrew quote runs right to left, but its bar sat on the far left, away
  # from where its text starts
  it "puts a Hebrew blockquote's bar where its text starts" do
    SiteSetting.support_mixed_text_direction = true
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        raw: "> שלום, זה ציטוט בעברית\n\n> And this one is in English",
      )
    sign_in(member)
    visit(post.url)
    expect(page).to have_css("#post_#{post.post_number} .cooked > blockquote[dir]", count: 2)
    bars = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("#post_#{post.post_number} .cooked > blockquote")].map((quote) => {
        const style = getComputedStyle(quote);
        return [style.direction, style.borderLeftWidth, style.borderRightWidth];
      })
    JS
    expect(bars).to eq([%w[rtl 0px 2px], %w[ltr 2px 0px]])
    expect_no_theme_errors
  end

  it "draws collapsible sections, quotes and link previews as hairline cards" do
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        raw:
          "[quote=\"#{member.username}, post:1, topic:#{topic.id}\"]\nI'm setting up a flip phone.\n[/quote]",
      )
    # written out rather than cooked, so the spec doesn't lean on the details
    # plugin or a onebox fetch
    post.update_column(:cooked, post.cooked + <<~HTML)
      <details><summary>Steps</summary><p>Turn it off and on.</p></details>
      <aside class="onebox allowlistedgeneric" data-onebox-src="https://example.com/">
        <header class="source"><a href="https://example.com/">example.com</a></header>
        <article class="onebox-body"><h3><a href="https://example.com/">Example</a></h3></article>
      </aside>
    HTML
    sign_in(member)
    visit("#{topic.relative_url}/#{post.post_number}")
    selector = "#post_#{post.post_number} .cooked"
    expect(page).to have_css("#{selector} details summary")
    expect(page).to have_css("#{selector} aside.onebox")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const post = document.querySelector("#{selector}");
        const details = post.querySelector("details");
        const quote = post.querySelector("aside.quote blockquote");
        const onebox = post.querySelector("aside.onebox");
        return {
          marker: getComputedStyle(details.querySelector("summary"), "::before").content,
          details: getComputedStyle(details).borderTopWidth,
          quoteBar: getComputedStyle(quote).borderLeftWidth,
          ring: getComputedStyle(onebox).boxShadow,
          onebox: getComputedStyle(onebox).borderTopWidth,
        };
      })()
    JS
    expect(looks).to eq(
      "marker" => '""',
      "details" => "1px",
      "quoteBar" => "0px",
      "ring" => "none",
      "onebox" => "1px",
    )

    find("#{selector} details summary").click
    expect(page).to have_css("#{selector} details[open]")
    turned =
      page.evaluate_script(
        "getComputedStyle(document.querySelector('#{selector} details summary'), '::before').rotate",
      )
    expect(turned).to eq("90deg")
    shot("post-blocks")
    expect_no_theme_errors
  end

  it "leaves a gap between New's All / Topics / Replies and the first card" do
    sign_in(member)
    visit("/new")
    expect(page).to have_css(".topic-replies-toggle-wrapper")
    expect(page).to have_css(".topic-list.jt-cards .topic-list-item")
    gap = page.evaluate_script(<<~JS)
      document.querySelector(".topic-list.jt-cards .topic-list-item").getBoundingClientRect().top -
        document.querySelector(".topic-replies-toggle-wrapper").getBoundingClientRect().bottom
    JS
    expect(gap).to be >= 8
    expect_no_theme_errors
  end

  # A face on a card opens that person's card, as in core's posters column,
  # rather than the topic under it
  it "opens a poster's user card from a topic card" do
    visit("/latest")
    card_css = ".topic-list.jt-cards .topic-list-item[data-topic-id='#{topic.id}']"
    find("#{card_css} .jt-card__people a[data-user-card]", match: :first).click
    expect(page).to have_css(".user-card.show")
    expect(page).to have_current_path("/latest")
    expect_no_theme_errors
  end

  # The forum's Topic List Item Click Animation component made a pressed topic
  # bounce; the cards' 1px nudge went unnoticed. Pressed, a card sinks to 97%;
  # let go, it springs back a little past full size. A press on a tag inside
  # leaves it be. Pressed at its edge, which the shrunk card no longer covers,
  # it still opens the topic.
  it "presses a topic card in and springs it back" do
    visit("/latest")
    # Capybara's no-animations style turns transitions off, and the spring is one
    page.execute_script(<<~JS)
      for (const style of document.querySelectorAll("style")) {
        if (style.textContent.includes("transition: none !important")) style.remove();
      }
    JS
    card_css = ".topic-list.jt-cards .topic-list-item[data-topic-id='#{topic.id}']"
    expect(page).to have_css("#{card_css} .discourse-tag")
    edge, tag = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector("#{card_css}");
        card.scrollIntoView({ block: "center" });
        window.jtRestHeight = card.offsetHeight;
        const box = card.getBoundingClientRect();
        const tag = card.querySelector(".discourse-tag").getBoundingClientRect();
        return [
          [box.left + 4, box.top + box.height / 2],
          [tag.left + tag.width / 2, tag.top + tag.height / 2],
        ];
      })()
    JS
    stop_next_click = <<~JS
      document.querySelector("#{card_css}").parentElement.addEventListener(
        "click",
        (event) => {
          event.preventDefault();
          event.stopPropagation();
        },
        { capture: true, once: true },
      )
    JS
    pressed = <<~JS
      (() => {
        const card = document.querySelector("#{card_css}");
        return {
          active: card.matches(":active"),
          scale: getComputedStyle(card).scale,
          shrinking: card.getAnimations().some((a) => a.transitionProperty === "scale"),
          same_height: card.offsetHeight === window.jtRestHeight,
        };
      })()
    JS

    page.execute_script(stop_next_click)
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(tag[0], tag[1])
      pw.mouse.down
    end
    expect(page.evaluate_script(pressed)).to include(
      "active" => true,
      "scale" => "none",
      "shrinking" => false,
    )
    page.driver.with_playwright_page { |pw| pw.mouse.up }

    page.driver.with_playwright_page do |pw|
      pw.mouse.move(edge[0], edge[1])
      pw.mouse.down
    end
    try_until_success do
      expect(page.evaluate_script(pressed)).to include("scale" => "0.97", "same_height" => true)
    end

    # let go without opening the topic, noting the card's size every frame
    page.execute_script(stop_next_click)
    page.execute_script(<<~JS)
      (() => {
        const card = document.querySelector("#{card_css}");
        const started = performance.now();
        window.jtSizes = [];
        const sample = () => {
          const scale = getComputedStyle(card).scale;
          window.jtSizes.push(scale === "none" ? 1 : parseFloat(scale));
          if (performance.now() - started < 1500) {
            requestAnimationFrame(sample);
          } else {
            window.jtSprung = true;
          }
        };
        requestAnimationFrame(sample);
      })()
    JS
    # the first samples are taken while it's still held, so the press is in them
    try_until_success { expect(page.evaluate_script("window.jtSizes.length")).to be >= 3 }
    page.driver.with_playwright_page { |pw| pw.mouse.up }
    try_until_success(timeout: 5) { expect(page.evaluate_script("window.jtSprung")).to eq(true) }
    sizes = page.evaluate_script("window.jtSizes")
    expect(sizes.min).to eq(0.97)
    expect(sizes.max).to be > 1
    expect(sizes.last).to eq(1)

    page.driver.with_playwright_page { |pw| pw.mouse.down }
    try_until_success { expect(page.evaluate_script(pressed)).to include("scale" => "0.97") }
    page.driver.with_playwright_page { |pw| pw.mouse.up }
    expect(page).to have_current_path(%r{/t/#{topic.slug}/#{topic.id}})
    expect_no_theme_errors
  end

  # Reduced motion: a pressed card is tinted, and doesn't shrink
  it "tints a pressed topic card instead of shrinking it for reduced motion", mobile: true do
    page.driver.with_playwright_page { |pw| pw.emulate_media(reducedMotion: "reduce") }
    visit("/latest")
    card_css = ".topic-list.jt-cards .topic-list-item[data-topic-id='#{topic.id}']"
    expect(page).to have_css(card_css)
    at = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector("#{card_css}");
        card.scrollIntoView({ block: "center" });
        const box = card.getBoundingClientRect();
        return [box.left + 4, box.top + box.height / 2];
      })()
    JS
    looks = <<~JS
      (() => {
        const style = getComputedStyle(document.querySelector("#{card_css}"));
        const tint = document.createElement("div");
        tint.style.background = "var(--jt-active)";
        document.body.append(tint);
        const pressed = getComputedStyle(tint).backgroundColor;
        tint.remove();
        return { scale: style.scale, tinted: style.backgroundColor === pressed };
      })()
    JS
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(at[0], at[1])
      pw.mouse.down
    end
    try_until_success do
      expect(page.evaluate_script(looks)).to eq("scale" => "none", "tinted" => true)
    end
    page.driver.with_playwright_page { |pw| pw.mouse.up }
    expect(page).to have_current_path(%r{/t/#{topic.slug}/#{topic.id}})
    expect_no_theme_errors
  end

  # Core's static pages: a 700px column at the interface size. The theme: a
  # reading column at the post's size, with a post's heading and list rhythm.
  it "sets the guidelines page in a reading column" do
    guidelines = Fabricate(:topic, user: admin, title: "Community guidelines for the forum")
    Fabricate(
      :post,
      topic: guidelines,
      user: admin,
      raw: "Be kind.\n\n## No ads\n\n- One\n- Two\n\nThat's all.",
    )
    SiteSetting.guidelines_topic_id = guidelines.id

    visit("/guidelines")
    expect(page).to have_css(".body-page h2", text: "No ads")
    width, size, indent = page.evaluate_script(<<~JS)
      [
        Math.round(document.querySelector(".body-page").getBoundingClientRect().width),
        getComputedStyle(document.querySelector(".body-page h2").parentElement).fontSize,
        getComputedStyle(document.querySelector(".body-page ul:not(.nav-pills)")).marginLeft,
      ]
    JS
    expect(width).to eq(704) # 44rem
    expect(size).to eq("17.0672px") # the post's reading size, not core's 16px
    expect(indent).to eq("0px") # a post's indent, not core's 40px
    expect_no_theme_errors
  end

  # Core's polls: square corners, flat grey bars with no track (a 0% option
  # shows nothing), the voter count in grey and the settings gear a bare
  # button (a grey box in dark mode). The theme: its radius, a track under
  # every result with your vote in the text colour, the count in the text
  # colour, a flat gear.
  it "draws a poll's results on tracks, with the voter's choice in the text colour" do
    post = PostCreator.create!(admin, topic_id: topic.id, raw: <<~MD)
      Which day?

      [poll]
      * Monday
      * Tuesday
      [/poll]
    MD
    monday = post.polls.first.poll_options.find_by(html: "Monday").digest
    # staff, so the gear has something to offer (close, export)
    DiscoursePoll::Poll.vote(admin, post.id, "poll", [monday])
    sign_in(admin)
    visit("#{topic.relative_url}/#{post.post_number}")
    poll = "#post_#{post.post_number} .poll"
    expect(page).to have_css("#{poll} .results li.chosen")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const poll = document.querySelector("#{poll}");
        const text = getComputedStyle(document.body).color;
        const tracks = [...poll.querySelectorAll(".results .bar-back")];
        return {
          rounded: getComputedStyle(poll).borderTopLeftRadius !== "0px",
          tracks: tracks.length,
          tracksShown: tracks.every((t) => getComputedStyle(t).backgroundColor !== "rgba(0, 0, 0, 0)"),
          chosen: getComputedStyle(poll.querySelector(".chosen .bar")).backgroundColor === text,
          count: getComputedStyle(poll.querySelector(".info-number")).color === text,
          gear: getComputedStyle(poll.querySelector(".poll-buttons .widget-dropdown-header")).backgroundColor,
        };
      })()
    JS
    expect(looks).to eq(
      "rounded" => true,
      "tracks" => 2,
      "tracksShown" => true,
      "chosen" => true,
      "count" => true,
      "gear" => "rgba(0, 0, 0, 0)",
    )
    shot("poll")
    expect_no_theme_errors
  end

  it "puts Me too on the post menu's line, next to the like count" do
    skip("needs discourse-solved") unless defined?(::DiscourseSolved)
    SiteSetting.solved_enabled = true
    SiteSetting.enable_solved_shared_issues = true
    category.upsert_custom_fields(DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD => "true")
    DiscourseSolved::AcceptedAnswerCache.reset_accepted_answer_cache
    sign_in(admin)
    visit(topic.relative_url)
    expect(page).to have_css("#post_1 .post-action-menu__solved-shared-issue")
    me_too, menu, post = page.evaluate_script(<<~JS)
      [
        "#post_1 .post-action-menu__solved-shared-issue",
        "#post_1 nav.post-controls .actions",
        "#post_1 .post__contents",
      ]
        .map((selector) => document.querySelector(selector).getBoundingClientRect())
        .map((r) => [Math.round(r.top + r.height / 2), Math.round(r.right)])
    JS
    expect(me_too[0]).to be_within(1).of(menu[0])
    expect(menu[1]).to be <= post[1]
    shot("me-too")
    expect_no_theme_errors
  end

  # Core's preferences: bold labels over small pills in a loose stack. The
  # theme: each group a card, the controls 2.4rem, Save on a ruled bar.
  it "shows each preferences group as a card with the theme's controls" do
    sign_in(member)
    visit("/u/#{member.username}/preferences/emails")
    expect(page).to have_css(".user-preferences .control-group .select-kit-header")
    card_border, control_height, save_height = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".user-preferences .form-vertical > .control-group")).borderTopWidth,
        Math.round(document.querySelector(".user-preferences .control-group .select-kit-header").getBoundingClientRect().height),
        Math.round(document.querySelector(".user-preferences .save-button .btn").getBoundingClientRect().height),
      ]
    JS
    expect(card_border).to eq("1px")
    expect(control_height).to eq(38) # 2.4rem
    expect(save_height).to eq(38)
    expect_no_theme_errors
  end

  # Core sets the Tracking page's two cards' width, and the theme's padding came
  # on top: on desktop they overlapped and the second ran past the page
  it "keeps the Tracking preferences' two cards apart" do
    sign_in(member)
    visit("/u/#{member.username}/preferences/tracking")
    wrapper = ".user-preferences__tracking-categories-tags-wrapper"
    expect(page).to have_css("#{wrapper} .control-group", minimum: 2)
    first, second, outer = page.evaluate_script(<<~JS)
      [
        ...[...document.querySelectorAll("#{wrapper} .control-group")].slice(0, 2),
        document.querySelector("#{wrapper}"),
      ].map((box) => {
        const rect = box.getBoundingClientRect();
        return [Math.round(rect.left), Math.round(rect.right)];
      })
    JS
    expect(first[1]).to be <= second[0]
    expect(second[1]).to be <= outer[1]
    expect_no_theme_errors
  end

  # On a 320px phone (a Qin F21) core's 300px multi-selects, inside the theme's
  # padded cards, made the preferences scroll sideways
  it "fits the Tracking preferences on a 320px phone", mobile: true do
    sign_in(member)
    resize_window(width: 320) do
      visit("/u/#{member.username}/preferences/tracking")
      expect(page).to have_css(".user-preferences .select-kit.multi-select")
      page_width, window_width = page.evaluate_script(<<~JS)
        [document.documentElement.scrollWidth, document.documentElement.clientWidth]
      JS
      expect(page_width).to eq(window_width)
      expect_no_theme_errors
    end
  end

  # Core sets a table as bare text: a grey header, 3px cells and a faint line
  # between rows. The theme: a hairline card with a sunken header strip,
  # roomy cells and a rule between rows.
  it "sets a table in a post as a card with a header strip" do
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        raw: "| Phone | Filter |\n|---|---|\n| Qin F21 | eGate |\n| Flip 3 | Mitzuyan |",
      )
    sign_in(member)
    visit("#{topic.relative_url}/#{post.post_number}")
    table = "#post_#{post.post_number} .cooked table"
    expect(page).to have_css("#{table} tbody tr", count: 2)
    looks = page.evaluate_script(<<~JS)
      (() => {
        const table = document.querySelector("#{table}");
        const th = getComputedStyle(table.querySelector("th"));
        const rows = table.querySelectorAll("tbody tr");
        return {
          frame: getComputedStyle(table).borderTopWidth,
          strip: th.backgroundColor !== "rgba(0, 0, 0, 0)",
          rule: getComputedStyle(rows[1].querySelector("td")).borderTopWidth,
          roomy: parseFloat(getComputedStyle(rows[0].querySelector("td")).paddingLeft) >= 8,
        };
      })()
    JS
    expect(looks).to eq("frame" => "1px", "strip" => true, "rule" => "1px", "roomy" => true)
    shot("table")
    expect_no_theme_errors
  end

  it "keeps a user title's pill to the size of its text on phones", mobile: true do
    admin.update!(title: "Forum Administrator")
    visit(topic.relative_url)
    expect(page).to have_css("#post_2 .names .user-title", text: "Forum Administrator")
    pill, text, names = page.evaluate_script(<<~JS)
      (() => {
        const title = document.querySelector("#post_2 .names .user-title");
        const text = document.createRange();
        text.selectNodeContents(title);
        return [title, text, title.closest(".names")]
          .map((e) => Math.round(e.getBoundingClientRect().width));
      })()
    JS
    expect(pill).to be < text + 30
    expect(pill).to be < names
    expect_no_theme_errors
  end

  # Core's suggested list is a bare table under a bold "want to read more?";
  # the theme: a divided card and a sentence.
  # Core lifts a user card's big avatar 3.3em above the card; on the theme's
  # hairline card it slipped out of place and covered the post behind it.
  it "keeps the avatar inside the user card" do
    sign_in(member)
    visit(topic.relative_url)
    find("#post_1 .topic-avatar a").click
    expect(page).to have_css(".user-card.show img.avatar")
    inside = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".user-card.show");
        return (
          card.querySelector("img.avatar").getBoundingClientRect().top >=
          card.getBoundingClientRect().top
        );
      })()
    JS
    expect(inside).to eq(true)
    expect_no_theme_errors
  end

  # jtech-tools' REQ-PM is a btn-small; on the user card it sat under Message
  # and Follow, which core sizes from 1rem, a size smaller and 8px shorter
  it "gives REQ-PM on a user card the size of the buttons above it" do
    SiteSetting.reqpm_enabled = true
    sign_in(member)
    visit(topic.relative_url)
    find("#post_2 .topic-avatar a").click
    expect(page).to have_css(".user-card.show .usercard-controls .reqpm-user-button")
    sizes = page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".user-card.show .usercard-controls .btn")]
        .filter((button) => button.getBoundingClientRect().width > 0)
        .map((button) => [
          getComputedStyle(button).fontSize,
          Math.round(button.getBoundingClientRect().height),
        ])
    JS
    expect(sizes.size).to be > 1
    expect(sizes.uniq.size).to eq(1)
    expect_no_theme_errors
  end

  # jtech-tools' REQ-PM page draws its own tabs: grey labels at the regular
  # weight, a 2px grey bar under the chosen one (half clipped by the scrolling
  # strip) and a scrollbar under the strip on a phone
  it "gives REQ-PM's tabs the look of the forum's other tabs" do
    SiteSetting.reqpm_enabled = true
    sign_in(member)
    tab_style = <<~JS
      ((active, other) => [
        getComputedStyle(active, "::after").height,
        getComputedStyle(active, "::after").backgroundColor,
        getComputedStyle(active).color,
        getComputedStyle(other).color,
        getComputedStyle(other).fontWeight,
      ])
    JS
    visit("/u/#{member.username}/preferences/account")
    expect(page).to have_css(".user-nav__preferences-account a.active")
    forum_tabs = page.evaluate_script(<<~JS)
      (#{tab_style})(
        document.querySelector(".user-nav__preferences-account a.active"),
        document.querySelector(".user-nav__preferences-security a")
      )
    JS
    visit("/reqpm")
    expect(page).to have_css(".reqpm-tabs .reqpm-tabs__tab.active")
    reqpm_tabs, bar, clipped = page.evaluate_script(<<~JS)
      [
        (#{tab_style})(
          document.querySelector(".reqpm-tabs__tab.active"),
          document.querySelector(".reqpm-tabs__tab:not(.active)")
        ),
        getComputedStyle(document.querySelector(".reqpm-tabs")).scrollbarWidth,
        document.querySelector(".reqpm-tabs").scrollHeight >
          document.querySelector(".reqpm-tabs").clientHeight,
      ]
    JS
    expect(forum_tabs[0]).to eq("1px")
    expect(reqpm_tabs).to eq(forum_tabs)
    expect(bar).to eq("none")
    expect(clipped).to eq(false)
    expect_no_theme_errors
  end

  # On a phone REQ-PM's four tabs don't fit and the strip scrolls, with no bar:
  # only a label cut at the edge showed there was more
  it "fades REQ-PM's tab strip at the edge that's cut off" do
    SiteSetting.reqpm_enabled = true
    sign_in(member)
    fades = <<~JS
      (() => {
        const strip = document.querySelector(".reqpm-tabs");
        const style = getComputedStyle(strip);
        return [
          strip.scrollWidth > strip.clientWidth,
          parseFloat(style.getPropertyValue("--jt-tabs-fade-start")),
          parseFloat(style.getPropertyValue("--jt-tabs-fade-end")),
        ];
      })()
    JS
    resize_window(width: 320) do
      visit("/reqpm")
      expect(page).to have_css(".reqpm-tabs .reqpm-tabs__tab", count: 4)
      scrolls, start_fade, end_fade = page.evaluate_script(fades)
      expect(scrolls).to eq(true)
      expect(start_fade).to eq(0)
      expect(end_fade).to be > 0
    end
    visit("/reqpm")
    expect(page).to have_css(".reqpm-tabs .reqpm-tabs__tab", count: 4)
    expect(page.evaluate_script(fades)).to eq([false, 0, 0])
    expect_no_theme_errors
  end

  # REQ-PM's strip of tabs scrolls, so it clips: the theme's outer focus ring
  # lost its top and bottom on a tab
  it "draws REQ-PM's tab focus ring inside the tab" do
    SiteSetting.reqpm_enabled = true
    sign_in(member)
    visit("/reqpm")
    expect(page).to have_css(".reqpm-tabs .reqpm-tabs__tab", count: 4)
    find("body").send_keys(:tab) # keyboard use, so focus counts as keyboard focus
    ring = page.evaluate_script(<<~JS)
      (() => {
        const tab = document.querySelector(".reqpm-tabs__tab:not(.active)");
        tab.focus();
        const style = getComputedStyle(tab);
        return [tab.matches(":focus-visible"), style.outlineStyle, parseFloat(style.outlineOffset) < 0];
      })()
    JS
    expect(ring).to eq([true, "solid", true])
    expect_no_theme_errors
  end

  # In a right-to-left interface (Hebrew) a strip of tabs starts at its right
  # edge and is cut off on the left, but its fade still ran left to right as
  # in English: the cut-off edge stayed hard and the start faded instead
  it "fades the cut-off edge of a strip of tabs in a right-to-left interface" do
    SiteSetting.allow_user_locale = true
    SiteSetting.reqpm_enabled = true
    member.update!(locale: "he")
    sign_in(member)
    resize_window(width: 320) do
      visit("/reqpm")
      expect(page).to have_css("html.rtl .reqpm-tabs .reqpm-tabs__tab", count: 4)
      mask =
        page.evaluate_script('getComputedStyle(document.querySelector(".reqpm-tabs")).maskImage')
      expect(mask).to start_with("linear-gradient(to left")
    end
    expect_no_theme_errors
  end

  it "puts the suggested topics under a topic on a card" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".more-topics__container .topic-list .topic-list-item")
    border, weight = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".more-topics__list .topic-list")).borderTopWidth,
        getComputedStyle(document.querySelector(".more-topics__browse-more")).fontWeight,
      ]
    JS
    expect(border).to eq("1px")
    expect(weight).to eq("400")
    expect_no_theme_errors
  end

  # On phones core floated a suggested topic's reply count after its title and
  # put the date at the end of the category line, so where they landed hung on
  # the title's length: at 320px (a Qin F21) a long title pushed the count down
  # beside the date
  it "keeps suggested topics' counts above their dates on a 320px phone", mobile: true do
    long =
      Fabricate(
        :topic,
        category: category,
        user: admin,
        title: "A much longer topic title about flip phones that wraps onto several lines",
      )
    Fabricate(:post, topic: long, user: admin, raw: "Body of the long topic.")
    sign_in(member)
    resize_window(width: 320) do
      visit(topic.relative_url)
      expect(page).to have_css(".more-topics__container .topic-list-item .posts-map", minimum: 2)
      rows = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(".more-topics__container .topic-list-item")].map((row) => {
          const count = row.querySelector(".posts-map").getBoundingClientRect();
          const date = row.querySelector(".num.activity").getBoundingClientRect();
          return [date.top >= count.bottom - 2, Math.abs(date.right - count.right) <= 1];
        })
      JS
      expect(rows.uniq).to eq([[true, true]])
      expect_no_theme_errors
    end
  end

  # On phones core makes every footer button an icon, Reply included
  it "keeps the word on the phone's Reply button", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(
      "#topic-footer-buttons .create .d-button-label",
      text: "Reply",
      visible: true,
    )
    expect_no_theme_errors
  end

  # Core mixes radii: square composer controls and Discard, 10px rows and
  # menus, 14px fields beside 12px buttons, circular avatars among rounded
  # boxes. The theme: one radius for controls, avatars as rounded boxes.
  it "gives every control one radius and draws avatars as rounded boxes" do
    sign_in(member)
    visit(topic.relative_url)
    find(".topic-footer-main-buttons .create").click
    expect(page).to have_css("#reply-control.open .save-or-cancel .discard-button")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const radius = (s) => getComputedStyle(document.querySelector(s)).borderTopLeftRadius;
        const control = radius("#reply-control .save-or-cancel .btn-primary");
        const avatar = getComputedStyle(document.querySelector(".topic-avatar img.avatar"));
        return {
          odd: [
            "#reply-control .composer-controls .toggle-minimize",
            "#reply-control .save-or-cancel .discard-button",
            "#reply-control .d-editor-textarea-wrapper",
            "#reply-control .d-editor-button-bar .btn:not(.composer-toggle-switch)",
            ".post-controls .actions .btn",
          ].filter((s) => radius(s) !== control),
          circle:
            avatar.borderTopLeftRadius === "50%" &&
            (!avatar.cornerShape || /round|[(]1[)]/.test(avatar.cornerShape)),
        };
      })()
    JS
    expect(looks).to eq("odd" => [], "circle" => false)
    shot("one-radius")
    expect_no_theme_errors
  end

  # "view 1 hidden reply" was core's bold uppercase grey line; the theme draws
  # it like the list's "last visit" divider. Core only renders it around
  # filtered posts, so the spec adds the same markup and checks its look.
  it "draws the hidden replies link as a centred divider" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".post-stream")
    gap = page.evaluate_script(<<~JS)
      (() => {
        const gap = document.createElement("div");
        gap.className = "gap";
        gap.textContent = "view 1 hidden reply";
        document.querySelector(".post-stream").appendChild(gap);
        const style = getComputedStyle(gap);
        const look = {
          display: style.display,
          case: style.textTransform,
          rule: getComputedStyle(gap, "::before").height,
        };
        gap.remove();
        return look;
      })()
    JS
    expect(gap).to eq("display" => "flex", "case" => "none", "rule" => "1px")
    expect_no_theme_errors
  end

  it "puts the tracking menu in the topic's row of buttons, without the explanation" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#topic-footer-buttons .notifications-tracking-trigger")
    expect(page).to have_no_css("#topic-footer-buttons .reason .text")
    tracking, reply = page.evaluate_script(<<~JS)
      ["#topic-footer-buttons .notifications-tracking-trigger", "#topic-footer-buttons .create"]
        .map((selector) => document.querySelector(selector).getBoundingClientRect())
        .map((r) => [Math.round(r.top), Math.round(r.left)])
    JS
    expect(tracking[0]).to eq(reply[0])
    expect(tracking[1]).to be < reply[1]
    expect_no_theme_errors
  end

  # On sidebar pages core placed the composer at the sidebar plus its gap,
  # without the page's gutter, so it started left of everything above it.
  it "starts the composer at the content's left edge on sidebar pages" do
    # the rich editor has no preview, so the composer takes core's previewless
    # layout (tests otherwise start in Markdown with the preview open)
    member.user_option.update!(composition_mode: UserOption.composition_mode_types[:rich])
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("body.has-sidebar-page")
    find(".topic-footer-main-buttons .create").click
    expect(page).to have_css("#reply-control.open.hide-preview")
    offset = page.evaluate_script(<<~JS)
      Math.round(
        document.querySelector("#reply-control").getBoundingClientRect().left -
          document.querySelector("#main-outlet").getBoundingClientRect().left
      )
    JS
    expect(offset).to eq(0)
    expect_no_theme_errors
  end

  # On narrower desktop windows core's composer ran past the posts and over the
  # timeline's buttons (from 925px up to about 1180px with core's columns, and
  # to about 1320px with DiscoTOC's 75/25 split on the live forum)
  it "ends the composer where the posts end when the timeline is beside them" do
    member.user_option.update!(composition_mode: UserOption.composition_mode_types[:rich])
    sign_in(member)
    resize_window(width: 1024) do
      visit(topic.relative_url)
      expect(page).to have_css(".topic-navigation.with-timeline")
      find(".topic-footer-main-buttons .create").click
      expect(page).to have_css("#reply-control.open.hide-preview")
      composer, posts, timeline = page.evaluate_script(<<~JS)
        ["#reply-control", ".container.posts > .row", ".topic-navigation"].map((selector) => {
          const rect = document.querySelector(selector).getBoundingClientRect();
          return [rect.left, rect.right].map(Math.round);
        })
      JS
      expect(composer[1]).to be_within(1).of(posts[1])
      expect(composer[1]).to be <= timeline[0]
      expect_no_theme_errors
    end
  end

  # On phones core puts a message's tag picker beside its title, but neither can
  # shrink below its own width, so the picker ran off the screen
  it "keeps a new message's tag picker on a phone's screen", mobile: true do
    SiteSetting.tagging_enabled = true
    SiteSetting.pm_tags_allowed_for_groups = Group::AUTO_GROUPS[:everyone].to_s
    sign_in(admin)
    visit("/new-message?username=#{member.username}")
    expect(page).to have_css("#reply-control .title-and-category .tags-input")
    tags_right, window_width = page.evaluate_script(<<~JS)
      [
        document.querySelector("#reply-control .title-and-category .tags-input").getBoundingClientRect().right,
        document.documentElement.clientWidth,
      ]
    JS
    expect(tags_right).to be <= window_width
    expect_no_theme_errors
  end

  it "lines the footer up with the page above it" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".jt-footer__inner")
    page_edges, footer_edges = page.evaluate_script(<<~JS)
      [[".sidebar-wrapper", "#main-outlet"], [".jt-footer__inner", ".jt-footer__inner"]]
        .map(([left, right]) => [
          document.querySelector(left).getBoundingClientRect().left,
          document.querySelector(right).getBoundingClientRect().right,
        ])
    JS
    expect(footer_edges[0]).to be_within(1).of(page_edges[0])
    expect(footer_edges[1]).to be_within(1).of(page_edges[1])
  end

  # Core lists tags as "name x 190" in floated columns; the theme makes each
  # a chip with the number alone in a pill, and the lists wrap.
  it "shows the tags page as chips, with the count alone in its pill" do
    Fabricate(:topic, category: category, user: admin, tags: [Fabricate(:tag, name: "ios")])
    Tag.ensure_consistency! # the counts the page shows
    sign_in(member)
    visit("/tags")
    expect(page).to have_css(".tags-index .tag-box", minimum: 2)
    expect(find(".tag-box", text: tag.name).find(".tag-count")).to have_text(/\A1\z/)

    display, android_top, ios_top = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".tags-index .tags-list")).display,
        ...[...document.querySelectorAll(".tags-index .tag-box")]
          .slice(0, 2)
          .map((box) => Math.round(box.getBoundingClientRect().top)),
      ]
    JS
    expect(display).to eq("flex")
    expect(android_top).to eq(ios_top) # side by side, not stacked
    expect_no_theme_errors
  end

  def horizontal_edges(*selectors)
    page.evaluate_script(<<~JS)
      #{selectors.to_json}
        .map((selector) => document.querySelector(selector).getBoundingClientRect())
        .map((r) => [Math.round(r.left), Math.round(r.right)])
    JS
  end

  # Gives each element keyboard focus and reports its focus ring: [outline
  # style, whether the ring reaches past the element, whether a box that clips
  # its overflow cuts it]. A pair [selector, ancestor] reads the ring off the
  # ancestor, for a link whose box takes the ring.
  def focus_rings(*targets)
    send_keys(:tab) # keyboard first, so focus() below counts as keyboard focus
    page.evaluate_script(<<~JS)
      #{targets.to_json}.map((target) => {
        const [selector, ringOn] = [].concat(target);
        const link = document.querySelector(selector);
        link.focus();
        const ringed = ringOn ? link.closest(ringOn) : link;
        const style = getComputedStyle(ringed);
        const reach = parseFloat(style.outlineWidth) + parseFloat(style.outlineOffset);
        const box = ringed.getBoundingClientRect();
        let cut = false;
        for (let el = ringed.parentElement; el !== document.documentElement; el = el.parentElement) {
          const s = getComputedStyle(el);
          if (s.overflowX === "visible" && s.overflowY === "visible") continue;
          const clip = el.getBoundingClientRect();
          cut ||=
            box.left - reach < clip.left - 0.5 ||
            box.top - reach < clip.top - 0.5 ||
            box.right + reach > clip.right + 0.5 ||
            box.bottom + reach > clip.bottom + 0.5;
        }
        return [style.outlineStyle, reach > 0, cut];
      })
    JS
  end

  # Core clips a post's names, the header's logo and the topic map's avatars
  # (overflow: hidden) right at the link's edge, which cut a keyboard focus
  # ring away, and takes the ring off suggested topics' titles.
  it "shows the whole focus ring on links in boxes that clip" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#post_1 .names .first a")
    expect(page).to have_css(".more-topics__container .topic-list a.title")
    rings =
      focus_rings(
        "#post_1 .names .first a",
        [".d-header .home-logo-wrapper-outlet a", ".home-logo-wrapper-outlet"],
        ".more-topics__container .topic-list a.title",
      )
    expect(rings).to all(eq(["solid", true, false]))
    expect_no_theme_errors
  end

  # On phones the name link is taller, for a bigger tap area
  it "shows the whole focus ring on a post's names on a phone", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css("#post_1 .names .first a")
    expect(focus_rings("#post_1 .names .first a")).to eq([["solid", true, false]])
    expect_no_theme_errors
  end

  # Suggested topics and the search page used to stop short of the right
  # edge the header, content and footer share
  it "runs suggested topics and the search page to the page's edges" do
    sign_in(member)

    visit(topic.relative_url)
    expect(page).to have_css(".more-topics__container .topic-list")
    wall, suggested = horizontal_edges("#main-outlet", ".more-topics__container")
    expect(suggested[1]).to be_within(1).of(wall[1])

    visit("/search?q=filter")
    expect(page).to have_css(".search-header .search-bar")
    wall, bar = horizontal_edges("#main-outlet", ".search-header .search-bar")
    expect(bar).to eq(wall)
    expect_no_theme_errors
  end

  # Core puts the bulk-select / sort row above the count, insets the count by
  # a different rule than the results (so it sat further in), and separates
  # results with margins. The theme makes the count the title, the row a
  # toolbar under it, and the results one divided card.
  it "lays the search page out as a count, a toolbar and a card of results" do
    SearchIndexer.enable
    SearchIndexer.index(topic, force: true)
    SearchIndexer.index(first_post, force: true)
    sign_in(member)
    visit("/search?q=filter")
    expect(page).to have_css(".fps-result-entries .fps-result", text: "Which filter works best")

    count, info, entries = page.evaluate_script(<<~JS)
        [".result-count", ".search-info", ".fps-result-entries"]
          .map((selector) => document.querySelector(selector).getBoundingClientRect())
          .map((r) => [Math.round(r.top), Math.round(r.bottom)])
      JS
    expect(count[1]).to be <= info[0]
    expect(info[1]).to be <= entries[0]

    wall, counted, card = horizontal_edges("#main-outlet", ".result-count", ".fps-result-entries")
    expect(counted).to eq(wall)
    expect(card).to eq(wall)
    border = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".fps-result-entries")).borderTopWidth
    JS
    expect(border).to eq("1px")
    expect_no_theme_errors
  end

  # Core fills a deleted post with bright pink and turns its name and buttons
  # red. The theme: a dashed outline over a faint hatch, everything in greys.
  it "shows staff a deleted post in greys, not pink and red" do
    # staff see a deleted reply only after "show deleted"; a deleted first
    # post is always in the stream (core keeps post 1), as on the live forum
    first_post.update_columns(deleted_at: Time.zone.now, deleted_by_id: admin.id)
    sign_in(admin)
    visit(topic.relative_url)
    expect(page).to have_css(".topic-post.deleted .regular > .cooked")
    looks = page.evaluate_script(<<~JS)
      (() => {
        const post = document.querySelector(".topic-post.deleted");
        const cooked = getComputedStyle(post.querySelector(".regular > .cooked"));
        const grey = (c) => {
          const [r, g, b] = c.match(/[0-9.]+/g).map(Number);
          return Math.max(r, g, b) - Math.min(r, g, b) < 12;
        };
        return {
          outline: cooked.borderTopStyle,
          fill: cooked.backgroundColor,
          name: grey(getComputedStyle(post.querySelector(".topic-meta-data")).color),
          buttons: grey(getComputedStyle(post.querySelector("nav.post-controls")).color),
        };
      })()
    JS
    expect(looks).to eq(
      "outline" => "dashed",
      "fill" => "rgba(0, 0, 0, 0)",
      "name" => true,
      "buttons" => true,
    )
    shot("deleted-post")
    expect_no_theme_errors
  end

  it "previews a topic's first post in Quick look" do
    sign_in(member)
    visit("/latest")
    card = find(".topic-list-item[data-topic-id='#{topic.id}']")
    card.hover # the button shows on hover where there is one
    card.find(".jt-card__peek").click
    expect(page).to have_css(".jt-quick-look .cooked", text: "blocks the browser")
    shot("quick-look")
    expect_no_theme_errors
  end

  # Core's row of post buttons scrolled sideways on phones: eight or nine
  # 38px buttons are wider than the column. The theme's row wraps instead.
  it "fits a post's buttons in the phone's column without scrolling", mobile: true do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".topic-post .post-controls .actions .btn")
    overflowing = page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".topic-post .post-controls")]
        .filter((row) => row.scrollWidth > row.clientWidth + 1).length
    JS
    expect(overflowing).to eq(0)
    expect_no_theme_errors
  end

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
  # It's a button beside the tabs' dropdown, "Online: 1", that pops out a box
  # with everyone. Only where the plugin is installed
  # (CI doesn't have it).
  it "shows who's online as a button beside the tabs that pops out everyone" do
    skip("needs the Who's Online plugin") unless defined?(::DiscourseWhosOnline)
    SiteSetting.whos_online_enabled = true
    SiteSetting.whos_online_display_public = true
    SiteSetting.whos_online_minimum_display = 1
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-online-box__toggle", exact_text: "Online: 1")
    expect(page).to have_no_css(".online_users_widget", visible: true)
    expect(page).to have_no_css(".sidebar-section[data-section-name='jt-online']")

    find(".jt-online-box__toggle").click
    expect(page).to have_css(".jt-online-box.--open")
    expect(page).to have_css(
      ".jt-online-box__people a[href='/u/#{member.username}'] img.jt-online-box__face",
    )
    find(".jt-online-box__toggle").click
    expect(page).to have_no_css(".jt-online-box.--open")
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
  # bookmarks and preferences, and none back to the top
  it "gives the footer an Account column and a way back to the top" do
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
      find(".jt-reader-toggle").click
      expect(page).to have_css("html.jt-reader")
      expect(page).to have_no_css(".sidebar-wrapper")
      find(".jt-reader-larger").click
      try_until_success { expect(page.evaluate_script(size)).to be > normal }
      find(".jt-reader-serif").click
      expect(page).to have_css("html.jt-reader--serif")
      shot("reader-mode")
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

  describe "table of contents" do
    # long sections, so a heading near the end can still scroll to the top
    let(:section) { "A line of the guide. " * 120 }

    fab!(:guide) do
      Fabricate(:topic, category: category, user: member, title: "A guide with a few sections")
    end

    def guide_post(raw)
      Fabricate(:post, topic: guide, user: member, raw: raw)
    end

    def location_hash
      page.evaluate_script("location.hash")
    end

    before do
      jtech_theme.update_setting(:table_of_contents_categories, category.id.to_s)
      jtech_theme.save!
    end

    it "lists the first post's headings in the timeline's column and jumps to them" do
      guide_post(
        "Intro.\n\n## Setup\n\n#{section}\n\n## Install\n\n#{section}\n\n### Check\n\n#{section}\n\n## Done\n\n#{section}",
      )
      visit(guide.relative_url)
      expect(page).to have_css(".jt-toc--open .jt-toc__link", count: 4)
      expect(page).to have_css(".topic-navigation .timeline-footer-controls")
      expect(page).to have_no_css(".timeline-scrollarea-wrapper")
      expect(page).to have_no_css(".jt-toc-inline")
      shot("table-of-contents")
      find(".jt-toc__link", text: "Install").click
      try_until_success { expect(location_hash).to match(/install/) }
      expect(page).to have_css(".jt-toc__link[aria-current='location']", text: "Install")

      # folded away, the timeline comes back
      find(".jt-toc__toggle").click
      expect(page).to have_css(".timeline-scrollarea-wrapper")
      expect(page).to have_no_css(".jt-toc__list")
      expect_no_theme_errors
    end

    it "shows a first post's contents as a card in the post on phones", mobile: true do
      guide_post(
        "Intro.\n\n## Setup\n\n#{section}\n\n## Install\n\n#{section}\n\n## Done\n\n#{section}",
      )
      visit(guide.relative_url)
      expect(page).to have_css("#post_1 .cooked details.jt-toc-inline")
      expect(page).to have_no_css(".jt-toc")
      find(".jt-toc-inline summary").click
      find(".jt-toc-inline .jt-toc__link", text: "Done").click
      try_until_success { expect(location_hash).to match(/done/) }
      shot("table-of-contents-card")
      expect_no_theme_errors
    end

    it "shows the card in the post instead where the timeline's column is slim" do
      guide_post(
        "Intro.\n\n## Setup\n\n#{section}\n\n## Install\n\n#{section}\n\n## Done\n\n#{section}",
      )
      # about 1000px wide, the timeline's column is under 100px
      page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 1000, height: 900) }
      visit(guide.relative_url)
      expect(page).to have_css("#post_1 .cooked details.jt-toc-inline")
      expect(page).to have_css(".topic-navigation .timeline-scrollarea-wrapper")
      expect(page).to have_no_css(".jt-toc")
    ensure
      page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 1400, height: 1400) }
    end

    it "leaves the card out behind the login gate", mobile: true do
      jtech_theme.update_setting(:gated_categories, category.id.to_s)
      jtech_theme.save!
      guide_post(
        "Intro.\n\n## Setup\n\n#{section}\n\n## Install\n\n#{section}\n\n## Done\n\n#{section}",
      )
      visit(guide.relative_url)
      expect(page).to have_css(".jt-gate")
      expect(page).to have_no_css(".jt-toc-inline")
    end

    it "keeps DiscoTOC's marker working outside the listed categories" do
      jtech_theme.update_setting(:table_of_contents_categories, "")
      jtech_theme.save!
      guide_post(
        "<div data-theme-toc=\"true\"> </div>\n\n## One\n\nA.\n\n## Two\n\nB.\n\n## Three\n\nC.",
      )
      visit(guide.relative_url)
      expect(page).to have_css(".jt-toc .jt-toc__link", count: 3)
    end

    it "leaves out a first post with too few headings" do
      guide_post("Intro.\n\n## One\n\nA.\n\n## Two\n\nB.")
      visit(guide.relative_url)
      expect(page).to have_css("#post_1 .cooked h2")
      expect(page).to have_no_css(".jt-toc")
      expect(page).to have_no_css(".jt-toc-inline")
    end
  end

  describe "voice messages" do
    before { SiteSetting.authorized_extensions = "jpg|png|m4a|ogg|webm" }

    # headless Chrome has no microphone: a tone stands in for one
    def fake_microphone
      page.execute_script(<<~JS)
        navigator.mediaDevices.getUserMedia = async () => {
          const context = new AudioContext();
          const tone = context.createOscillator();
          const out = context.createMediaStreamDestination();
          tone.connect(out);
          tone.start();
          return out.stream;
        };
      JS
    end

    def open_composer
      visit("/latest")
      find("#create-topic").click
      expect(page).to have_css("#reply-control.open .d-editor-button-bar")
    end

    it "records a voice message and adds it to the post as audio" do
      sign_in(admin)
      open_composer
      fake_microphone
      find(".d-editor-button-bar .jt-voice").click
      find(".jt-voice__record").click
      expect(page).to have_css(".jt-voice__meter.--recording .jt-voice__clock", text: "0:01")
      find(".jt-voice__stop").click
      expect(page).to have_css("audio.jt-voice__preview")
      shot("voice-message")
      find(".jt-voice__add").click
      expect(page).to have_no_css(".d-modal.jt-voice")
      try_until_success(timeout: 10) do
        expect(find("#reply-control .d-editor-input").value).to match(
          %r{!\[voice-message\|(audio|video)\]\(upload://\w+\.(m4a|ogg|webm)\)},
        )
      end
      expect_no_theme_errors
    end

    it "leaves the microphone out when the forum doesn't take audio files" do
      SiteSetting.authorized_extensions = "jpg|png"
      sign_in(admin)
      open_composer
      expect(page).to have_no_css(".d-editor-button-bar .jt-voice")
    end
  end

  describe "header and sidebar edges" do
    it "keeps a topic's title clear of the logo, and the avatar on the page's right edge" do
      Fabricate(:post, topic: topic, user: admin, raw: "A long reply.\n\n" * 60)
      sign_in(member)
      visit(topic.relative_url)
      page.execute_script("window.scrollTo(0, 900)")
      expect(page).to have_css(".d-header .extra-info-wrapper .topic-link")
      gap, avatar_right, content_right = page.evaluate_script(<<~JS)
        (() => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector(".d-header .topic-link"));
          const logo = document.querySelector(".d-header .title").getBoundingClientRect();
          const avatar = document.querySelector("#toggle-current-user img.avatar").getBoundingClientRect();
          const content = document.querySelector("#main-outlet").getBoundingClientRect();
          return [range.getBoundingClientRect().left - logo.right, avatar.right, content.right];
        })()
      JS
      expect(gap).to be >= 14
      expect(avatar_right).to be_within(1).of(content_right)
      expect_no_theme_errors
    end

    # Core lines the timeline up on the left of its column, so it stopped
    # about 100px short of the edge the header, title and suggested list share
    it "ends the timeline and its buttons at the page's right edge" do
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".timeline-container .jt-jump__bottom")
      edges = page.evaluate_script(<<~JS)
        [
          "#toggle-current-user",
          "#main-outlet",
          ".timeline-container .topic-timeline",
          ".timeline-footer-controls .jt-jump__bottom",
        ].map((selector) => Math.round(document.querySelector(selector).getBoundingClientRect().right))
      JS
      expect(edges.max - edges.min).to be <= 1
      expect_no_theme_errors
    end

    # Core's fixed 690px post text, in a column wider than that, beside a
    # timeline column twice the timeline's width, left some 200px empty
    it "fills the room beside the timeline with the posts" do
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".timeline-container .jt-jump__bottom")
      gap, overflow = page.evaluate_script(<<~JS)
        [
          document.querySelector(".topic-timeline").getBoundingClientRect().left -
            document.querySelector("#post_1 .topic-body").getBoundingClientRect().right,
          document.documentElement.scrollWidth - window.innerWidth,
        ]
      JS
      expect(gap).to be_between(16, 64)
      expect(overflow).to eq(0)
      expect_no_theme_errors
    end

    # Each attribute write restyles. The overlay scrollbar rewrote its class
    # on every scroll event (classList.add with the class already there), and
    # the posts' width was written on <html>, restyling the page, each time
    # the column grew as posts loaded
    it "doesn't rewrite the scrollbar's or the page's attributes while scrolling" do
      8.times { |i| Fabricate(:post, topic: topic, raw: "Reply #{i}. " + "A line. " * 120) }
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".jt-scrollbar")
      writes = page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        const count = { scrollbar: 0, html: 0 };
        const watch = (el, key) =>
          new MutationObserver((m) => (count[key] += m.length)).observe(el, {
            attributes: true,
            attributeFilter: ["class", "style"],
          });
        watch(document.querySelector(".jt-scrollbar"), "scrollbar");
        watch(document.documentElement, "html");
        let y = 0;
        const t0 = performance.now();
        const step = () => {
          window.scrollTo(0, (y += 40));
          if (performance.now() - t0 < 1500) requestAnimationFrame(step);
          else setTimeout(() => done(count), 100);
        };
        requestAnimationFrame(step);
      JS
      # the thumb shows once when scrolling starts; <html> gets nothing
      expect(writes["scrollbar"]).to be <= 2
      expect(writes["html"]).to be <= 1
      expect_no_theme_errors
    end

    # The logo stuck out 20px to the left of the sidebar it heads
    it "starts the logo where the sidebar's icons start" do
      SiteSetting.logo = Fabricate(:image_upload)
      sign_in(member)
      visit("/latest")
      expect(page).to have_css(".d-header img#site-logo")
      expect(page).to have_css(".sidebar-section-link .sidebar-section-link-prefix")
      logo, icon = page.evaluate_script(<<~JS)
        [".d-header img#site-logo", ".sidebar-section-link .sidebar-section-link-prefix"].map(
          (selector) => document.querySelector(selector).getBoundingClientRect().left
        )
      JS
      expect(logo).to be_within(1).of(icon)
      expect_no_theme_errors
    end

    it "opens a sidebar link to a page outside the forum as a page load" do
      section = Fabricate(:sidebar_section, title: "Links", public: true, user: admin)
      homepage = Fabricate(:sidebar_url, name: "Homepage", value: "/home")
      Fabricate(:sidebar_section_link, sidebar_section: section, linkable: homepage, user: admin)
      sign_in(member)
      visit("/latest")
      page.execute_script("window.jtSamePage = true")
      find(".sidebar-section-link[href='/home']").click
      try_until_success { expect(page.evaluate_script("window.jtSamePage")).to be_nil }
      expect(page).to have_current_path("/home")
    end
  end

  describe "login gate" do
    def gate(categories: "", tags: "")
      jtech_theme.update_setting(:gated_categories, categories)
      jtech_theme.update_setting(:gated_tags, tags)
      jtech_theme.save!
    end

    it "fades a gated category's topic into a prompt to log in or sign up" do
      gate(categories: category.id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css("body.jt-gated")
      expect(page).to have_css(".jt-gate__title", text: "Log in to keep reading")
      expect(page).to have_css(
        ".jt-gate__text",
        text: "Topics in #{category.name} are for members.",
      )
      expect(page).to have_css(".jt-gate__sign-up")
      shot("gate")
      expect_no_theme_errors

      find(".jt-gate__log-in").click
      expect(page).to have_current_path("/login")
    end

    it "fits a phone", mobile: true do
      gate(categories: category.id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css(".jt-gate .jt-gate__sign-up")
      shot("gate")
      expect_no_theme_errors
    end

    # The forum offers Hebrew and the theme's sentence around the category's
    # name is English: read right to left, it came out scrambled
    it "reads the prompt's sentence in its own direction in a Hebrew interface" do
      SiteSetting.default_locale = "he"
      gate(categories: category.id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css("html.rtl .jt-gate__text", text: category.name)
      direction =
        page.evaluate_script(
          '[document.querySelector(".jt-gate__text").getAttribute("dir"), getComputedStyle(document.querySelector(".jt-gate__text")).direction]',
        )
      expect(direction).to eq(%w[auto ltr])
    end

    it "gates topics with a gated tag" do
      gate(tags: tag.name)
      visit(topic.relative_url)
      expect(page).to have_css(".jt-gate")
    end

    # In Hebrew core mirrors the "Browse open categories" arrow to point left,
    # but its hover nudge still went right, against the arrow
    it "nudges the browse arrow the way it points in a right-to-left interface" do
      SiteSetting.default_locale = "he"
      gate(categories: category.id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css("html.rtl .jt-gate__browse .d-icon")
      find(".jt-gate__browse").hover
      nudge =
        page.evaluate_script(
          'getComputedStyle(document.querySelector(".jt-gate__browse .d-icon")).translate',
        )
      expect(nudge).to eq("-2px")
    end

    it "only offers Log in when sign-ups are closed" do
      SiteSetting.invite_only = true
      gate(categories: category.id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css(".jt-gate__log-in.btn-primary")
      expect(page).to have_no_css(".jt-gate__sign-up")
    end

    it "leaves members and other categories alone" do
      gate(categories: Fabricate(:category).id.to_s)
      visit(topic.relative_url)
      expect(page).to have_css(".topic-post")
      expect(page).to have_no_css(".jt-gate")

      gate(categories: category.id.to_s)
      sign_in(member)
      visit(topic.relative_url)
      expect(page).to have_css(".topic-post")
      expect(page).to have_no_css(".jt-gate")
      expect(page).to have_no_css("body.jt-gated")
    end
  end

  # The sidebar fades at the edge where more links are, with a scroll-driven
  # animation. Under a blanket `animation-duration: 0s !important` (a
  # reduce-motion user style, or Capybara's own animation switch) the fade sat
  # at its end: the top of a sidebar that hadn't scrolled faded instead of its
  # cut-off bottom
  it "fades the sidebar's cut-off bottom, not its top, under a no-animations style" do
    sign_in(member)
    resize_window(height: 400) do
      visit("/latest")
      expect(page).to have_css(".sidebar-wrapper .sidebar-sections")
      fades = page.evaluate_script(<<~JS)
        (() => {
          const style = document.createElement("style");
          style.textContent = "*, *::before, *::after { animation-duration: 0s !important; }";
          document.head.appendChild(style);
          const sections = document.querySelector(".sidebar-wrapper .sidebar-sections");
          const computed = getComputedStyle(sections);
          return [
            sections.scrollHeight > sections.clientHeight,
            parseFloat(computed.getPropertyValue("--jt-fade-top")),
            parseFloat(computed.getPropertyValue("--jt-fade-bottom")) > 0,
          ];
        })()
      JS
      expect(fades).to eq([true, 0, true])
    end
    expect_no_theme_errors
  end

  it "draws Discourse's icons with Lucide's outline set" do
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-notifications .d-icon-bell")
    icon, drawn = page.evaluate_script(<<~JS)
      (() => {
        const id = document
          .querySelector(".jt-header-notifications .d-icon-bell use")
          .getAttribute("href")
          .slice(1);
        return [id, !!document.querySelector(`symbol#${id}`)];
      })()
    JS
    expect(icon).to eq("jt-bell")
    expect(drawn).to eq(true)
    expect_no_theme_errors
  end

  # Icons the map left out stayed Font Awesome's heavier solid ones beside the
  # outlines: Account and Profile in a member's preferences, and the topics
  # and active users on the About page, among others
  it "draws the preferences tabs' and the About page's icons with Lucide too" do
    sign_in(member)
    icons = <<~JS
      ((selectors) => selectors.map((selector) => {
        const id = document.querySelector(`${selector} .d-icon use`).getAttribute("href").slice(1);
        return [id, !!document.querySelector(`symbol#${id}`)];
      }))
    JS
    visit("/u/#{member.username}/preferences/account")
    expect(page).to have_css(".user-nav__preferences-profile .d-icon")
    tabs =
      page.evaluate_script(
        "#{icons}(['.user-nav__preferences-account', '.user-nav__preferences-profile'])",
      )
    expect(tabs).to eq([["jt-circle-user", true], ["jt-id-card", true]])
    visit("/about")
    expect(page).to have_css(".about__activities-item.active-users .d-icon")
    activities =
      page.evaluate_script(
        "#{icons}(['.about__activities-item.topics', '.about__activities-item.active-users'])",
      )
    expect(activities).to eq([["jt-scroll-text", true], ["jt-users", true]])
    expect_no_theme_errors
  end

  # Core draws a video as a black box with square corners, between images and
  # cards with rounded ones
  it "rounds videos like the images around them" do
    post = Fabricate(:post, topic: topic, user: admin, raw: "A video.")
    post.update_columns(
      cooked: '<div class="video-container"><video preload="none" controls></video></div>',
    )
    sign_in(member)
    visit(post.url)
    expect(page).to have_css("#post_#{post.post_number} .cooked .video-container")
    corner = page.evaluate_script(<<~JS)
      (() => {
        const video = getComputedStyle(document.querySelector("#post_#{post.post_number} .video-container"));
        const probe = document.createElement("div");
        probe.style.borderRadius = "var(--jt-radius-sm)";
        document.body.appendChild(probe);
        const image = getComputedStyle(probe).borderTopLeftRadius;
        probe.remove();
        return [video.borderTopLeftRadius === image, image !== "0px", video.overflow];
      })()
    JS
    expect(corner).to eq([true, true, "clip"])
    expect_no_theme_errors
  end

  # Core draws FormKit's fields (the composer's Insert link, invites, user
  # notes, the admin's settings) with its own solid grey border and, focused,
  # a 2px ring in the accent; the theme's fields have a hairline over a faint
  # fill and, focused, a soft glow
  it "draws FormKit's fields like the theme's other fields" do
    sign_in(member)
    visit(topic.relative_url)
    find("#topic-footer-buttons .create").click
    expect(page).to have_css("#reply-control.open .d-editor-button-bar button.link")
    find("#reply-control .d-editor-button-bar button.link").click
    expect(page).to have_css(".upsert-hyperlink-modal .form-kit__control-input.link-text")
    find(".upsert-hyperlink-modal .link-url").click
    looks = page.evaluate_script(<<~JS)
      (() => {
        const modal = document.querySelector(".upsert-hyperlink-modal");
        const probe = document.createElement("div");
        probe.style.background = "var(--jt-fill)";
        probe.style.border = "1px solid var(--jt-border-strong)";
        modal.appendChild(probe);
        const expected = getComputedStyle(probe);
        const idle = getComputedStyle(modal.querySelector(".link-text"));
        const focused = getComputedStyle(modal.querySelector(".link-url"));
        const looks = [
          idle.backgroundColor === expected.backgroundColor,
          idle.borderTopColor === expected.borderTopColor,
          focused.outlineStyle,
          focused.boxShadow !== "none",
        ];
        probe.remove();
        return looks;
      })()
    JS
    expect(looks).to eq([true, true, "none", true])
    expect_no_theme_errors
  end

  # Windows' high contrast mode draws every button's border, and core gives
  # the topic map's stats no padding: each number and word touched its frame
  it "gives the topic map's stats room inside their frames in high contrast" do
    visit(topic.relative_url)
    stat = ".topic-map__stats :is(.fk-d-menu__trigger, .topic-map__stat)"
    expect(page).to have_css(stat)
    padding = "getComputedStyle(document.querySelector('#{stat}')).paddingLeft"
    expect(page.evaluate_script(padding)).to eq("0px")

    page.driver.with_playwright_page { |pw| pw.emulate_media(forcedColors: "active") }
    expect(page.evaluate_script(padding)).not_to eq("0px")
  end

  it "shows the dark palette when the browser prefers dark" do
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    background = page.evaluate_script("getComputedStyle(document.body).backgroundColor")
    expect(background).to eq("rgb(0, 0, 0)")
    shot("dark-latest")
    visit(topic.relative_url)
    expect(page).to have_css(".topic-post")
    shot("dark-topic")
    expect_no_theme_errors
  end

  # Printing drops a dark palette's black page but kept its white text (Chrome
  # printed posts in a faint grey, others in white), and in both modes the
  # sidebar printed in a column beside the posts
  it "prints a topic in dark mode as black text on white, without the sidebar" do
    sign_in(member)
    visit(topic.relative_url)
    expect(page).to have_css(".topic-post .cooked")
    expect(page).to have_css(".sidebar-wrapper")
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark", media: "print") }
    text, sidebar, left = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.querySelector(".topic-post .cooked")).color,
        getComputedStyle(document.querySelector(".sidebar-wrapper")).display,
        Math.round(document.querySelector("#main-outlet").getBoundingClientRect().left),
      ]
    JS
    page.driver.with_playwright_page { |pw| pw.emulate_media(media: "screen") }
    expect(text).to eq("rgb(0, 0, 0)")
    expect(sidebar).to eq("none")
    expect(left).to be < 50
    expect_no_theme_errors
  end

  # Core's secondary text (timeline dates, "1 Reply", "view 1 hidden reply",
  # the topic's category in the header) used greys that read at 2.5:1 to
  # 3.4:1. Every grey core and the theme put text in reaches WCAG AA, on the
  # page and on the sunken surface, in light and dark.
  it "keeps secondary text at 4.5:1 or better in light and dark" do
    contrast = <<~JS
      (() => {
        const rgb = (c) => c.match(/[0-9.]+/g).slice(0, 3).map(Number);
        const lum = ([r, g, b]) => {
          const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
        };
        const probe = document.createElement("div");
        document.body.appendChild(probe);
        const resolve = (prop, value) => {
          probe.style[prop] = value;
          return rgb(getComputedStyle(probe)[prop]);
        };
        const surfaces = ["var(--secondary)", "var(--jt-surface-sunken)"].map((v) =>
          resolve("backgroundColor", v)
        );
        const worst = {};
        for (const grey of [
          "--primary-medium",
          "--primary-med-or-secondary-high",
          "--header_primary-high",
          "--jt-text-subtle",
        ]) {
          const fg = lum(resolve("color", `var(${grey})`));
          worst[grey] = Math.min(
            ...surfaces.map((bg) => {
              const b = lum(bg);
              return (Math.max(fg, b) + 0.05) / (Math.min(fg, b) + 0.05);
            })
          );
        }
        probe.remove();
        return Object.fromEntries(Object.entries(worst).filter(([, ratio]) => ratio < 4.5));
      })()
    JS

    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-card")
    expect(page.evaluate_script(contrast)).to eq({})

    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    visit("/latest")
    expect(page).to have_css(".jt-card")
    expect(page.evaluate_script(contrast)).to eq({})
    expect_no_theme_errors
  end

  # Core draws a key in a post as a grey 3px key with a thick bottom edge; the
  # theme's other keycaps are a sunken chip with a hairline and 5px corners
  it "draws keys in a post like the theme's other keycaps" do
    post =
      Fabricate(:post, topic: topic, user: admin, raw: "Press <kbd>Ctrl</kbd> and <kbd>K</kbd>.")
    sign_in(member)
    visit(post.url)
    expect(page).to have_css("#post_#{post.post_number} .cooked kbd", count: 2)
    key = page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.querySelector("#post_#{post.post_number} .cooked kbd"));
        const probe = document.createElement("div");
        probe.style.backgroundColor = "var(--jt-surface-sunken)";
        document.body.appendChild(probe);
        const sunken = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return [
          style.borderRadius,
          style.borderBottomWidth === style.borderTopWidth,
          style.backgroundColor === sunken,
        ];
      })()
    JS
    expect(key).to eq(["5px", true, true])
    expect_no_theme_errors
  end

  # Discourse Dark is stock Discourse on JTech Dim's greys: the page goes to
  # Dim's #161616, and the forum takes Discourse's look (html.jt-vanilla),
  # Font Awesome icons included
  it "lets people pick Discourse Dark, stock Discourse on soft greys" do
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    sign_in(member)
    preferences = PageObjects::Pages::UserPreferencesInterface.new.visit(member)
    dark = PageObjects::Components::SelectKit.new(".dark-color-scheme .select-kit")
    # the theme's own default, by name rather than core's "-1"
    expect(dark).to have_selected_name("JTech Dark")
    dark.expand
    expect(dark).to have_no_option_name("JTech Dim")
    dark.select_row_by_name("Discourse Dark")
    preferences.save_changes

    visit("/latest")
    expect(page).to have_css("html.jt-vanilla")
    # stock Discourse's topic list: its rows, not the theme's cards, under
    # its row of tabs, not the dropdown
    expect(page).to have_css(".topic-list .topic-list-item")
    expect(page).to have_no_css(".topic-list.jt-cards")
    expect(page).to have_css("#navigation-bar > li > a.active")
    expect(page).to have_no_css(".list-control-toggle-link-trigger")
    background, header, sprite = page.evaluate_script(<<~JS)
      [
        getComputedStyle(document.body).backgroundColor,
        getComputedStyle(document.querySelector(".d-header"), "::before").backgroundColor,
        document.querySelector(".sidebar-section-link-prefix .d-icon use")?.getAttribute("href"),
      ]
    JS
    expect(background).to eq("rgb(22, 22, 22)")
    # the top bar darker than the page, as stock's
    expect(header).to eq("rgb(10, 10, 10)")
    expect(sprite).not_to start_with("#jt-")
    shot("discourse-dark-latest")
    expect_no_theme_errors
  end

  describe "the sidebar's palette menu" do
    let(:background) { "getComputedStyle(document.body).backgroundColor" }

    def scheme_id(name)
      jtech_theme.color_schemes.find_by(name: name).id
    end

    def pick(name)
      find(".jt-palette-menu").click
      find(".jt-palettes__option", exact_text: name).click
    end

    it "switches a member's palette on the spot and keeps it on every device" do
      sign_in(member)
      visit("/latest")
      expect(page).to have_css(".jt-card")

      pick("Nord")
      try_until_success { expect(page.evaluate_script(background)).to eq("rgb(236, 239, 244)") }
      try_until_success do
        expect(member.user_option.reload.color_scheme_id).to eq(scheme_id("Nord Light"))
      end
      expect(member.user_option.dark_scheme_id).to eq(scheme_id("Nord Dark"))
      shot("palette-nord")

      visit("/latest")
      expect(page).to have_css(".jt-card")
      expect(page.evaluate_script(background)).to eq("rgb(236, 239, 244)")
      find(".jt-palette-menu").click
      expect(page).to have_css(".jt-palettes__option[aria-checked='true']", exact_text: "Nord")
      shot("palette-menu")

      # back to black and white: saved as the theme's default
      find(".jt-palettes__option", exact_text: "JTech").click
      try_until_success { expect(page.evaluate_script(background)).to eq("rgb(255, 255, 255)") }
      try_until_success { expect(member.user_option.reload.color_scheme_id).to eq(-1) }
      expect(member.user_option.dark_scheme_id).to eq(-1)
      expect_no_theme_errors
    end

    it "keeps a visitor's palette in this browser, and gives a Discourse one Discourse's look" do
      visit("/latest")
      expect(page).to have_css(".jt-card")

      pick("Gruvbox")
      try_until_success { expect(page.evaluate_script(background)).to eq("rgb(251, 241, 199)") }
      visit("/latest")
      expect(page).to have_css(".jt-card")
      expect(page.evaluate_script(background)).to eq("rgb(251, 241, 199)")

      expect(page).to have_no_css("html.jt-vanilla")

      # stock Discourse's look, Font Awesome icons and all: the page reloads
      # to swap the icons
      pick("Discourse")
      expect(page).to have_css("html.jt-vanilla")
      try_until_success { expect(page.evaluate_script(background)).to eq("rgb(255, 255, 255)") }
      visit("/latest")
      expect(page).to have_css("html.jt-vanilla")
      expect(page).to have_no_css(".sidebar-section-link-prefix .d-icon use[href^='#jt-']")
      expect_no_theme_errors
    end

    it "sets the lists' density, Gmail's way, and keeps it in this browser" do
      topic.update!(excerpt: "Setting up a flip phone that blocks the browser.")
      sign_in(member)
      visit("/latest")
      expect(page).to have_css(".topic-list.jt-cards .topic-excerpt")

      find(".jt-density-menu").click
      find(".jt-palettes.--density .jt-palettes__option", text: "Compact").click
      expect(page).to have_css("html.jt-density-compact")
      expect(page).to have_no_css(".topic-list.jt-cards .topic-excerpt")

      visit("/latest")
      expect(page).to have_css("html.jt-density-compact")
      expect(page).to have_css(".jt-card")
      expect(page).to have_no_css(".topic-list.jt-cards .topic-excerpt")

      find(".jt-density-menu").click
      expect(page).to have_css(
        ".jt-palettes.--density .jt-palettes__option[aria-checked='true']",
        text: "Compact",
      )
      find(".jt-palettes.--density .jt-palettes__option", text: "Default").click
      expect(page).to have_no_css("html.jt-density-compact")
      expect(page).to have_css(".topic-list.jt-cards .topic-excerpt")
      expect_no_theme_errors
    end

    it "is left out when the theme setting is off" do
      jtech_theme.update_setting(:palette_menu, false)
      jtech_theme.save!
      sign_in(member)
      visit("/latest")
      expect(page).to have_css(".jt-card")
      expect(page).to have_no_css(".jt-palette-menu")
      expect(page).to have_css(".jt-density-menu")
    end
  end

  # Picking a palette in preferences previews it with a stylesheet core leaves
  # in the page until a reload, after the head's palette links; switching to
  # light flipped only those, so the page stayed dark
  it "switches to light after a dark palette was previewed in preferences" do
    SiteSetting.interface_color_selector = "sidebar_footer"
    member.user_option.update!(interface_color_mode: UserOption::DARK_MODE)
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    sign_in(member)
    PageObjects::Pages::UserPreferencesInterface.new.visit(member)
    dark = PageObjects::Components::SelectKit.new(".dark-color-scheme .select-kit")
    dark.expand
    dark.select_row_by_name("Discourse Dark")
    # the preview waits on the server compiling Discourse Dark's stylesheet
    expect(page).to have_css(
      "link#cs-preview-dark[href*='discourse-dark']",
      visible: :all,
      wait: 10,
    )
    background = "getComputedStyle(document.body).backgroundColor"
    try_until_success { expect(page.evaluate_script(background)).to eq("rgb(22, 22, 22)") }

    find(".interface-color-selector").click
    find(".interface-color-selector__light-option").click
    try_until_success { expect(page.evaluate_script(background)).to eq("rgb(255, 255, 255)") }

    # and back to dark: the previewed palette, not the one the page loaded with
    find(".interface-color-selector").click
    find(".interface-color-selector__dark-option").click
    try_until_success { expect(page.evaluate_script(background)).to eq("rgb(22, 22, 22)") }
    expect_no_theme_errors
  end

  # The header's light/dark icon is off unless header_color_toggle is on; the
  # sidebar's Color mode menu (Discourse's) and the command menu switch either
  # way
  it "switches light / dark from the sidebar, and from the header only when asked" do
    SiteSetting.interface_color_selector = "sidebar_footer"
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-notifications")
    expect(page).to have_css(".sidebar-footer-actions .interface-color-selector")
    expect(page).to have_no_css(".jt-header-theme")
    find(".jt-header-search__button").click
    find(".jt-cmdk__input").fill_in(with: "light")
    expect(page).to have_css(".jt-cmdk__item", text: "Switch light / dark")
    shot("color-mode-sidebar")

    jtech_theme.update_setting(:header_color_toggle, true)
    jtech_theme.save!
    visit("/latest")
    expect(page).to have_css(".sidebar-footer-actions .interface-color-selector")
    find(".jt-header-theme button").click
    background = "getComputedStyle(document.body).backgroundColor"
    try_until_success { expect(page.evaluate_script(background)).to eq("rgb(0, 0, 0)") }
    expect_no_theme_errors
  end
end
