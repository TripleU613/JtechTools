# frozen_string_literal: true

require "rails_helper"

# The JTech theme in a browser, part 2 of 4. Setup, and what the
# suite covers: spec/support/jtech_theme_context.rb.
RSpec.describe "JTech theme" do
  include_context "jtech theme"

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
end
