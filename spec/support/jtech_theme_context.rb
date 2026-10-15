# frozen_string_literal: true

require_relative "../../db/migrate/20261015000002_keep_jtech_words_for_existing_installs"

# Installs the bundled JTech theme, makes it the default and walks the main
# pages on desktop and mobile. Fails when the theme throws, logs a theme error,
# trips a deprecation (system specs raise on those), or a JTech surface that
# should render doesn't. This is the CI guard for "a Discourse update broke the
# theme": CI runs against Discourse `latest`.
#
# Screenshots land in tmp/capybara/jtech_theme/ (uploaded by the Feature
# Screenshots workflow).
#
# Shared by spec/system/jtech_theme_part*_spec.rb: the suite is split into
# parts so CI's parallel processes share it (as one file it ran past the
# job's 30 minutes on its own).
RSpec.shared_context "jtech theme" do
  # with JTech's own words, which a new install doesn't get (their defaults
  # are neutral): the hero's subtitle, the footer's notice, the home icon
  fab!(:jtech_theme) do
    DiscourseJtechTheme::Installer.sync_now
    theme = DiscourseJtechTheme::Installer.theme
    KeepJtechWordsForExistingInstalls::THEME_SETTINGS.each do |name, (_, value)|
      theme.update_setting(name.to_sym, value)
    end
    theme.save!
    theme
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
end
