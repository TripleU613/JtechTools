# frozen_string_literal: true

require "rails_helper"

# The JTech theme in a browser, part 4 of 4. Setup, and what the
# suite covers: spec/support/jtech_theme_context.rb.
# Run in their own CI job (JTECH_THEME_SPECS=1): see the context.
RSpec.describe "JTech theme", if: ENV["JTECH_THEME_SPECS"].present? do
  include_context "jtech theme"

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

  # A post's header: the name, the title under it, and core's box of post
  # infos (the reply-to tab, the date) at the top right. Since the reply-to
  # tab became a pill with the name in it, on a phone it took the middle of
  # the row and squeezed the name and title into a column, with the date out
  # at the edge, centred on both lines. The posts are a year old, so their
  # dates are as long as they get ("Jun 2025").
  describe "a post's header" do
    fab!(:asker) { Fabricate(:user, username: "Lamden613", trust_level: TrustLevel[2]) }
    fab!(:moderator) do
      Fabricate(
        :moderator,
        username: "anonymousfliphones",
        title: "Forum Moderator, Phone Distributor",
      )
    end
    fab!(:quoter) { Fabricate(:moderator, username: "kosherboy", title: "Forum Moderator") }
    # as long as a username gets
    fab!(:long_named) do
      Fabricate(:user, username: "averylongusername_42", trust_level: TrustLevel[2])
    end

    fab!(:thread) do
      Fabricate(:topic, category: category, user: asker, title: "Qin F21 Pro ROMs and the bands")
    end
    fab!(:question) do
      Fabricate(:post, topic: thread, user: asker, raw: "Is this ROM the stock one?")
    end
    fab!(:aside) do
      Fabricate(
        :post,
        topic: thread,
        user: member,
        raw: "The ROM messes it up so F30 bands come last.",
      )
    end
    fab!(:answer) do
      Fabricate(
        :post,
        topic: thread,
        user: moderator,
        raw: "Looks custom",
        reply_to_post_number: question.post_number,
        reply_to_user_id: asker.id,
      )
    end
    fab!(:follow_up) do
      Fabricate(
        :post,
        topic: thread,
        user: quoter,
        raw:
          "[quote=\"#{member.username}, post:#{aside.post_number}, topic:#{thread.id}\"]\nThe ROM messes it up so F30 bands come last.\n[/quote]\n\nHow do I know if my bands got messed up?",
        reply_to_post_number: aside.post_number,
        reply_to_user_id: member.id,
      )
    end
    fab!(:long_post) do
      Fabricate(:post, topic: thread, user: long_named, raw: "Mine came with the bands in order.")
    end
    fab!(:long_reply) do
      Fabricate(:post, topic: thread, user: member, raw: "Which ROM do you have?")
      Fabricate(
        :post,
        topic: thread,
        user: moderator,
        raw: "Then yours is the stock one.",
        reply_to_post_number: long_post.post_number,
        reply_to_user_id: long_named.id,
      )
    end

    before do
      Post.where(topic: thread).update_all(created_at: 16.months.ago, updated_at: 16.months.ago)
      Group.refresh_automatic_groups!
      Group.find(Group::AUTO_GROUPS[:moderators]).update!(
        flair_icon: "shield-halved",
        flair_bg_color: "5A29E4",
        flair_color: "FFFFFF",
      )
      [moderator, quoter].each do |mod|
        mod.update!(flair_group_id: Group::AUTO_GROUPS[:moderators])
      end
    end

    # Where each part of a post's header sits, rounded to whole pixels: the
    # name's link, the title and the date's link rather than core's boxes
    # around them, which carry padding for focus rings.
    def header(post)
      page.evaluate_script(<<~JS)
        (() => {
          const post = document.querySelector("#post_#{post.post_number}");
          const box = (selector) => {
            const rect = post.querySelector(selector).getBoundingClientRect();
            return {
              left: Math.round(rect.left),
              right: Math.round(rect.right),
              top: Math.round(rect.top),
              bottom: Math.round(rect.bottom),
              middle: Math.round((rect.top + rect.bottom) / 2),
            };
          };
          const cut = (selector) => {
            const element = post.querySelector(selector);
            return element.scrollWidth > element.clientWidth;
          };
          return {
            name: box(".names .first a"),
            title: box(".names .user-title"),
            date: box("a.post-date"),
            tab: box(".reply-to-tab"),
            meta: box(".topic-meta-data"),
            // the unread dot, while it shows
            dot: post.querySelector(".read-state svg") && box(".read-state svg"),
            name_cut: cut(".names .first"),
            title_cut: cut(".names .user-title"),
            tab_cut: cut(".reply-to-tab span"),
          };
        })()
      JS
    end

    def open_thread
      page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
      sign_in(member)
      visit("/t/#{thread.slug}/#{thread.id}/#{answer.post_number}")
      expect(page).to have_css("#post_#{answer.post_number} .reply-to-tab", text: asker.username)
      expect(page).to have_css("#post_#{follow_up.post_number} .reply-to-tab")
      expect(page).to have_css("#post_#{long_reply.post_number} .reply-to-tab")
      wait_for_avatars
    end

    # The headers' avatars drawn, so a screenshot shows them as people see them
    def wait_for_avatars
      drawn = <<~JS
        [...document.querySelectorAll(".topic-post :is(.topic-avatar, .reply-to-tab) img.avatar")]
          .every((img) => img.complete && img.naturalWidth > 0)
      JS
      try_until_success { expect(page.evaluate_script(drawn)).to eq(true) }
    end

    it "keeps the reply-to tab in the top right corner on phones, the date under it",
       mobile: true do
      open_thread
      shot("post-header")

      [answer, follow_up, long_reply].each do |post|
        at = header(post)
        # the tab on the name's line, in the corner
        expect(at["tab"]["middle"]).to be_within(3).of(at["name"]["middle"])
        expect(at["tab"]["left"]).to be > at["name"]["right"]
        expect(at["tab"]["right"]).to be_within(2).of(at["meta"]["right"])
        # the date under it, on the title's line, the unread dot beside it
        expect(at["date"]["top"]).to be >= at["tab"]["bottom"]
        expect(at["date"]["middle"]).to be_between(at["title"]["top"], at["title"]["bottom"])
        expect(at["date"]["right"]).to be_within(2).of(at["meta"]["right"])
        expect(at["dot"]["middle"]).to be_within(3).of(at["date"]["middle"]) if at["dot"]
        # the whole name and title: a long title wraps in its pill
        expect(at["name_cut"]).to eq(false)
        expect(at["title_cut"]).to eq(false)
        # the whole name in the tab, unless there's no room left for it
        expect(at["tab_cut"]).to eq(post == long_reply)
      end

      visit("/t/#{thread.slug}/#{thread.id}/#{long_reply.post_number}")
      expect(page).to have_css("#post_#{long_reply.post_number} .reply-to-tab", text: "averylong")
      wait_for_avatars
      shot("post-header-long-name")
      expect_no_theme_errors
    end

    it "keeps the reply-to tab beside the date on a computer" do
      open_thread
      shot("post-header")

      at = header(answer)
      expect(at["tab"]["right"]).to be <= at["date"]["left"]
      expect(at["tab"]["middle"]).to be_within(3).of(at["date"]["middle"])
      expect(at["name_cut"]).to eq(false)
      expect(at["title_cut"]).to eq(false)
      expect_no_theme_errors
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
      gap, overflow, anchor = page.evaluate_script(<<~JS)
        [
          document.querySelector(".topic-timeline").getBoundingClientRect().left -
            document.querySelector("#post_1 .topic-body").getBoundingClientRect().right,
          document.documentElement.scrollWidth - window.innerWidth,
          getComputedStyle(document.querySelector(".posts-wrapper")).overflowAnchor,
        ]
      JS
      expect(gap).to be_between(16, 64)
      expect(overflow).to eq(0)
      # the wrapper is a container: Safari leapt as posts were cloaked (#309)
      expect(anchor).to eq("none")
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

  # The Reactions plugin's picker as a row in the post's menu
  # (reaction_rollout), with as many reactions as the forum might turn on.
  describe "reactions as a row" do
    fab!(:reader) { Fabricate(:user, username: "jt_reader", trust_level: TrustLevel[2]) }

    let(:reply) { replies[1] }
    let(:post_selector) { "#post_#{reply.post_number}" }
    let(:open_row) { "#{post_selector} .discourse-reactions-picker.is-expanded" }

    before do
      SiteSetting.discourse_reactions_enabled_reactions =
        "+1|laughing|open_mouth|clap|confetti_ball|hugs|trophy|tada|fire|pray|thinking|100|eyes|rocket"
    end

    def open_reply
      sign_in(reader)
      visit("#{topic.relative_url}/#{reply.post_number}")
      expect(page).to have_css("#{post_selector} .discourse-reactions-reaction-button")
      page.execute_script(
        "document.querySelector(#{post_selector.to_json}).scrollIntoView({ block: 'center' })",
      )
    end

    def box(selector)
      page.evaluate_script(<<~JS)
        (() => {
          const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
          return { left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top), bottom: Math.round(r.bottom) };
        })()
      JS
    end

    def row_scrolls?
      page.evaluate_script(<<~JS)
        (() => {
          const row = document.querySelector("#{open_row} .discourse-reactions-picker-container");
          return row.scrollWidth > row.clientWidth;
        })()
      JS
    end

    it "rolls them out to the left of the heart, in the post's menu, when pointed at" do
      open_reply
      heart = "#{post_selector} .discourse-reactions-reaction-button"
      before_left = box(heart)["left"]
      find(heart).hover
      expect(page).to have_css(open_row)
      row = box("#{open_row} .discourse-reactions-picker-container")
      menu = box("#{post_selector} nav.post-controls")
      # in the menu's line, not over the post, and the heart didn't move
      expect(row["top"]).to be >= menu["top"]
      expect(row["bottom"]).to be <= menu["bottom"]
      expect(row["right"]).to be <= box(heart)["left"]
      expect(box(heart)["left"]).to eq(before_left)
      # no button for it with a mouse
      expect(page).to have_no_css("#{post_selector} .post-action-menu__jt-reaction-rollout")
      shot("reactions-row")

      find("#{open_row} .pickable-reaction.fire").click
      expect(page).to have_no_css(open_row)
      try_until_success do
        expect(
          DiscourseReactions::ReactionUser.joins(:reaction).where(
            user: reader,
            post: reply,
            reaction: {
              reaction_value: "fire",
            },
          ),
        ).to exist
      end
      expect_no_theme_errors
    end

    it "scrolls a row that doesn't fit with the mouse wheel" do
      SiteSetting.discourse_reactions_enabled_reactions +=
        "|grinning|smiley|smile|grin|joy|wink|blush|innocent|heart_eyes|star_struck|sunglasses|nerd_face"
      # already reacted to: the plugin's count comes before the heart
      DiscourseReactions::ReactionManager.new(
        reaction_value: "fire",
        user: Fabricate(:user),
        post: reply,
      ).toggle!
      resize_window(width: 1000, height: 900) do
        open_reply
        expect(page).to have_css(
          "#{post_selector} .post-controls .discourse-reactions-actions",
          count: 2,
        )
        find("#{post_selector} .discourse-reactions-reaction-button").hover
        expect(page).to have_css(open_row)
        shot("reactions-row-narrow")
        expect(row_scrolls?).to eq(true)
        find("#{open_row} .pickable-reaction.laughing").hover
        scrolled = page.evaluate_script("window.scrollY")
        page.driver.with_playwright_page { |pw| pw.mouse.wheel(0, 300) }
        try_until_success do
          expect(
            page.evaluate_script(
              "document.querySelector('#{open_row} .discourse-reactions-picker-container').scrollLeft",
            ),
          ).to be > 0
        end
        # the row's, not the page's
        expect(page.evaluate_script("window.scrollY")).to eq(scrolled)
      end
    end

    it "opens it with a tap on the button beside the heart on phones, on the heart's line",
       mobile: true do
      open_reply
      heart = "#{post_selector} .discourse-reactions-reaction-button"
      button = "#{post_selector} .post-action-menu__jt-reaction-rollout"
      find(button).click
      expect(page).to have_css(open_row)
      row = box("#{open_row} .discourse-reactions-picker-container")
      expect(row["top"]).to be < box(heart)["bottom"]
      expect(row["bottom"]).to be > box(heart)["top"]
      # the rest of the menu stepped aside, Reply stays; what doesn't fit scrolls
      expect(page).to have_no_css("#{post_selector} .post-action-menu__copy-link")
      expect(page).to have_css("#{post_selector} .post-action-menu__reply")
      expect(row_scrolls?).to eq(true)
      shot("reactions-row")

      find(button).click
      expect(page).to have_no_css(open_row)
      expect(page).to have_css("#{post_selector} .post-action-menu__copy-link")
      expect_no_theme_errors
    end

    it "leaves the plugin's picker over the post when switched off" do
      jtech_theme.update_setting(:reaction_rollout, false)
      jtech_theme.save!
      open_reply
      find("#{post_selector} .discourse-reactions-reaction-button").hover
      expect(page).to have_css(open_row)
      expect(
        page.evaluate_script("getComputedStyle(document.querySelector('#{open_row}')).position"),
      ).to eq("absolute")
      expect(page).to have_no_css(".post-action-menu__jt-reaction-rollout")
    end
  end
end
