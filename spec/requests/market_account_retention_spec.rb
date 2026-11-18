# frozen_string_literal: true

RSpec.describe "Marketplace account retention" do
  fab!(:user)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_market_account_retention = true
    SiteSetting.jtech_market_origin = "https://market.jtechforums.org"
    SiteSetting.enable_discourse_connect_provider = true
    SiteSetting.discourse_connect_provider_secrets =
      "market.jtechforums.org|market-secret\nother.example|other-secret"
  end

  def handoff(origin = "https://market.jtechforums.org", secret = "market-secret")
    sso = DiscourseConnectProvider.new
    sso.sso_secret = secret
    sso.nonce = SecureRandom.hex
    sso.return_sso_url = "#{origin}/api/v1/auth/discourse/callback"
    get sso.to_url("/session/sso_provider")
  end

  def protected?
    UserCustomField.exists?(user_id: user.id, name: DiscourseMarketAccounts::FIELD, value: "true")
  end

  it "marks a member only after an authenticated, signed marketplace handoff" do
    sign_in(user)
    handoff
    expect(response.status).to eq(302)
    expect(response.location).to start_with("https://market.jtechforums.org/")
    expect(protected?).to eq(true)
  end

  it "does not mark a signed-out visitor or a forged request" do
    handoff
    expect(protected?).to eq(false)
    sign_in(user)
    handoff("https://market.jtechforums.org", "wrong-secret")
    expect(response.status).to eq(422)
    expect(protected?).to eq(false)
  end

  it "does not mark a valid sign-in to another application" do
    sign_in(user)
    handoff("https://other.example", "other-secret")
    expect(response.status).to eq(302)
    expect(protected?).to eq(false)
  end

  it "does not let a member mark their own account through profile edits" do
    sign_in(user)
    put "/u/#{user.username}.json",
        params: {
          custom_fields: {
            DiscourseMarketAccounts::FIELD => "true",
          },
        }
    expect(protected?).to eq(false)
  end

  it "honors the module and master switches without blocking ordinary SSO" do
    sign_in(user)
    SiteSetting.jtech_market_account_retention = false
    handoff
    expect(response.status).to eq(302)
    expect(protected?).to eq(false)
    SiteSetting.jtech_market_account_retention = true
    SiteSetting.jtech_enabled = false
    handoff
    expect(response.status).to eq(302)
    expect(protected?).to eq(false)
  end
end
