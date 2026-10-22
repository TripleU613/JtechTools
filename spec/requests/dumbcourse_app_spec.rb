# frozen_string_literal: true

require "rails_helper"

# The Dumbcourse page: served with a strict policy, carrying its boot data
# as inert JSON that no setting can break out of.
RSpec.describe "Dumbcourse app page" do
  fab!(:user) { Fabricate(:user, username: "flipper") }

  before { SiteSetting.dumbcourse_enabled = true }

  def boot_data
    json = response.body[%r{<script type="application/json" id="dc-boot">(.*?)</script>}m, 1]
    expect(json).to be_present
    JSON.parse(json)
  end

  describe "security headers" do
    before do
      sign_in(user)
      get "/dumb/"
    end

    it "sends a strict content security policy" do
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to include("default-src 'self'")
      expect(csp).to match(%r{script-src 'self' 'sha256-[A-Za-z0-9+/=]+'(;|$)})
      expect(csp).to include("frame-ancestors 'self'")
      expect(csp).to include("object-src 'none'")
      expect(csp).to include("base-uri 'none'")
      expect(csp).not_to include("unsafe-eval")
      expect(csp).not_to match(/script-src[^;]*unsafe-inline/)
    end

    it "does not allow framing by other sites or MIME sniffing" do
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "allows the one inline script by its exact hash" do
      inline = response.body[%r{<script>(.*?)</script>}m, 1]
      expect(inline).to be_present
      hash = Digest::SHA256.base64digest(inline)
      expect(response.headers["Content-Security-Policy"]).to include("'sha256-#{hash}'")
    end
  end

  describe "boot data" do
    it "can't be broken out of by a site setting" do
      # Discourse strips tags from the real setting; stub it to prove the
      # page escapes whatever it gets.
      allow(SiteSetting).to receive(:title).and_return(%q{</script><script>alert("x")</script>&<>})
      sign_in(user)
      get "/dumb/"

      expect(response.body).not_to include(%q{<script>alert("x")})
      expect(boot_data["siteTitle"]).to eq(%q{</script><script>alert("x")</script>&<>})
      expect(response.body).to include("<title>&lt;/script&gt;&lt;script&gt;alert(&quot;x&quot;)")
    end

    it "carries the signed-in user, a CSRF token and the forum's categories" do
      category = Fabricate(:category, name: "Flip Phones")
      sign_in(user)
      get "/dumb/"

      data = boot_data
      expect(data["currentUser"]).to include("id" => user.id, "username" => "flipper")
      expect(data["csrf"]).to be_present
      expect(data["categories"].map { |c| c["name"] }).to include("Flip Phones")
      expect(data["notificationTypes"]["mentioned"]).to eq(Notification.types[:mentioned])
      expect(data["basePath"]).to eq("/dumb")
      expect(data.dig("auth", "pairing")).to eq(true)
      expect(category).to be_present
    end

    it "has no user for signed-out visitors" do
      get "/dumb/"
      expect(response.status).to eq(200)
      expect(boot_data["currentUser"]).to be_nil
    end
  end

  describe "use, for its badges" do
    before { SiteSetting.jtech_enabled = true }

    it "counts the day a signed-in member opens it, once, and not for its files" do
      sign_in(user)
      get "/dumb/"
      get "/dumb/latest"
      get "/dumb/dumbcourse.js", params: { v: "abc" }

      expect(user.reload.custom_fields[DiscourseDumbcourse::Usage::DAYS_FIELD].to_i).to eq(1)
    end

    it "marks the posts its composer sends" do
      # in the trust level groups, which may post
      writer = Fabricate(:user, refresh_auto_groups: true)
      sign_in(writer)
      post "/posts.json",
           params: {
             title: "Written on a flip phone",
             raw: "Typed on the keypad, one letter at a time.",
             dumbcourse: true,
           }

      expect(response.status).to eq(200)
      post = Post.find(response.parsed_body["id"])
      expect(post.custom_fields[DiscourseDumbcourse::Usage::POST_FIELD]).to eq(true)
    end
  end

  describe "signed-out visitors" do
    it "go to sign in, remembering where they were headed" do
      get "/dumb/t/some-topic/12"
      expect(response).to redirect_to("/dumb/login?next=%2Ft%2Fsome-topic%2F12")
    end

    it "can open the sign-in, sign-up and reset screens" do
      %w[
        login
        login/device
        signup
        password-reset
        password-reset/abc123
        email-login/abc
        activate-account/abc
        help
        preferences
      ].each do |path|
        get "/dumb/#{path}"
        expect(response.status).to eq(200), "#{path} → #{response.status}"
      end
    end

    it "can load the app's files" do
      get "/dumb/dumbcourse.js", params: { v: "abc" }
      expect(response.status).to eq(200)
      expect(response.media_type).to eq("text/javascript")
      expect(response.headers["Cache-Control"]).to include("immutable")

      get "/dumb/dumbcourse.css"
      expect(response.status).to eq(200)
      expect(response.headers["Cache-Control"]).not_to include("immutable")
    end
  end

  describe "colours" do
    def palette(name, paper, ink, accent, selectable: false)
      Fabricate(
        :color_scheme,
        name: name,
        theme: theme,
        user_selectable: selectable,
        color_scheme_colors: [
          ColorSchemeColor.new(name: "primary", hex: ink),
          ColorSchemeColor.new(name: "secondary", hex: paper),
          ColorSchemeColor.new(name: "tertiary", hex: accent),
        ],
      )
    end

    fab!(:theme)
    let!(:light) { palette("Forum Light", "ffffff", "111111", "0055aa") }
    let!(:dark) { palette("Forum Dark", "050505", "eeeeee", "66aaff") }
    let!(:sepia) { palette("Sepia", "f8f4ec", "2b2118", "8a4b1f", selectable: true) }
    let!(:midnight) { palette("Midnight", "0b1220", "e2e8f0", "60a5fa", selectable: true) }

    before do
      theme.update!(color_scheme_id: light.id, dark_color_scheme_id: dark.id)
      SiteSetting.default_theme_id = theme.id
    end

    def tokens
      style = response.body[%r{<style>(.*?)</style>}m, 1]
      expect(style).to be_present
      {
        dark: style[/:root\{(.*?)\}/, 1].to_s.scan(/--([\w-]+):(#\h+);/).to_h,
        light: style[/html\.light\{(.*?)\}/, 1].to_s.scan(/--([\w-]+):(#\h+);/).to_h,
      }
    end

    it "takes the forum theme's palettes" do
      get "/dumb/"
      expect(tokens[:dark]).to include("bg" => "#050505", "fg" => "#eeeeee", "accent" => "#66aaff")
      expect(tokens[:light]).to include("surface" => "#ffffff", "accent" => "#0055aa")
    end

    it "takes the reader's own palettes, this device's over their account's" do
      user.user_option.update!(color_scheme_id: sepia.id, dark_scheme_id: midnight.id)
      sign_in(user)
      get "/dumb/"
      expect(tokens[:light]).to include("surface" => "#f8f4ec", "accent" => "#8a4b1f")
      expect(tokens[:dark]).to include("bg" => "#0b1220", "accent" => "#60a5fa")

      cookies[:color_scheme_id] = light.id.to_s
      get "/dumb/"
      expect(tokens[:light]).to include("accent" => "#0055aa")
    end

    it "ignores a palette the reader may not use" do
      sepia.update!(user_selectable: false)
      user.user_option.update!(color_scheme_id: sepia.id)
      sign_in(user)
      get "/dumb/"
      expect(tokens[:light]).to include("accent" => "#0055aa")
    end
  end

  it "is not served when switched off" do
    SiteSetting.dumbcourse_enabled = false
    sign_in(user)
    get "/dumb/"
    expect(response.status).to eq(404)
  end

  describe "mod elections" do
    fab!(:admin)

    before do
      SiteSetting.jtech_enabled = true
      SiteSetting.mod_elections_enabled = true
      user.update!(created_at: 1.year.ago)
      user.change_trust_level!(TrustLevel[2])
    end

    it "says whether they're on, and marks a vote due until it's cast" do
      sign_in(user)
      get "/dumb/"
      expect(boot_data["modElectionsEnabled"]).to eq(true)
      expect(boot_data.dig("currentUser", "mod_election_vote_due")).to eq(0)

      election =
        DiscourseModElections::Lifecycle.create!(
          admin,
          seats: 1,
          nominations_open_at: 1.minute.ago,
          voting_open_at: 3.days.from_now,
          voting_close_at: 6.days.from_now,
        )
      # Two for the one seat: with no more candidates than seats there's no
      # Vote Week.
      2.times do
        DiscourseModElections::Nominations.run!(
          Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago),
          election,
          "",
        )
      end
      DiscourseModElections::Lifecycle.end_phase!(election, admin)

      get "/dumb/"
      expect(boot_data.dig("currentUser", "mod_election_vote_due")).to eq(1)

      DiscourseModElections::Voting.cast!(user, election, [election.candidates.first.id])
      get "/dumb/"
      expect(boot_data.dig("currentUser", "mod_election_vote_due")).to eq(0)
    end

    it "says they're off when the module is" do
      SiteSetting.mod_elections_enabled = false
      sign_in(user)
      get "/dumb/"
      expect(boot_data["modElectionsEnabled"]).to eq(false)
    end
  end
end
