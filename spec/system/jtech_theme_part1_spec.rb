# frozen_string_literal: true

require "rails_helper"

# The JTech theme in a browser, part 1 of 4. Setup, and what the
# suite covers: spec/support/jtech_theme_context.rb.
# Run in their own CI job (JTECH_THEME_SPECS=1): see the context.
RSpec.describe "JTech theme", if: ENV["JTECH_THEME_SPECS"].present? do
  include_context "jtech theme"

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

  # Issue #353: advanced search took a search first, then the results page's
  # Advanced filters. The menu goes to the search page with them open, and
  # so does Ctrl+Shift+K.
  it "opens advanced search from the command menu, and with Ctrl+Shift+K" do
    SiteSetting.chat_enabled = false
    sign_in(member)
    visit("/latest")
    expect(page).to have_css(".jt-header-search__keys")

    send_keys([:control, "k"])
    find(".jt-cmdk__input").fill_in(with: "advanced")
    expect(page).to have_css(".jt-cmdk__item.--active", text: I18n.t("js.search.open_advanced"))
    expect(page).to have_css(".jt-cmdk__item.--active .jt-cmdk__keys kbd", count: 3)
    send_keys(:enter)
    expect(page).to have_current_path(%r{/search\?expanded=true})
    expect(page).to have_css(".advanced-filters.--is-expanded .search-advanced-filters")
    # the Enter that picked it isn't let go of in the page's search field,
    # which searched for nothing and shut the filters
    expect(page).to have_no_css(".fps-invalid")

    visit("/latest")
    expect(page).to have_css(".jt-header-search__keys")
    send_keys([:control, :shift, "k"])
    expect(page).to have_current_path(%r{/search\?expanded=true})
    expect(page).to have_css(".advanced-filters.--is-expanded .search-advanced-filters")
    expect_no_theme_errors
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
end
