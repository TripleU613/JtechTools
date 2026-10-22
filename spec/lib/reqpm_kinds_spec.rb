# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseReqpm::Kinds do
  def normalize(**attrs)
    described_class.normalize!(**attrs)
  end

  def reason_for(**attrs)
    normalize(**attrs)
    nil
  rescue DiscourseReqpm::Kinds::Invalid => e
    [e.field, e.reason]
  end

  it "rejects unknown kinds" do
    expect(reason_for(kind: "fax", value: "123")).to eq(%i[kind unknown])
  end

  describe "phone numbers (phone, sms, whatsapp)" do
    it "accepts common formats" do
      %w[phone sms whatsapp].each do |kind|
        expect(normalize(kind: kind, value: " +1 (718) 555-0100 ")[:value]).to eq(
          "+1 (718) 555-0100",
        )
      end
      expect(normalize(kind: "phone", value: "0527.123.456")[:value]).to eq("0527.123.456")
    end

    describe "default country code" do
      it "adds +1 to a 10-digit number typed without one" do
        expect(normalize(kind: "whatsapp", value: "646-820-1413")[:value]).to eq("+1 646-820-1413")
        expect(normalize(kind: "sms", value: "(718) 555-0100")[:value]).to eq("+1 (718) 555-0100")
      end

      it "adds just the + when the number already starts with the code" do
        expect(normalize(kind: "phone", value: "1 646 820 1413")[:value]).to eq("+1 646 820 1413")
      end

      it "turns the 00 international prefix into +" do
        expect(normalize(kind: "whatsapp", value: "00972 52 123 4567")[:value]).to eq(
          "+972 52 123 4567",
        )
      end

      it "leaves numbers it can't place alone" do
        expect(normalize(kind: "phone", value: "052-123-4567")[:value]).to eq("052-123-4567")
        expect(normalize(kind: "phone", value: "555-0100")[:value]).to eq("555-0100")
        expect(normalize(kind: "phone", value: "+44 20 7946 0958")[:value]).to eq(
          "+44 20 7946 0958",
        )
      end

      it "follows the setting, and can be turned off" do
        SiteSetting.reqpm_default_country_code = "972"
        expect(normalize(kind: "phone", value: "5212345678")[:value]).to eq("+972 5212345678")

        SiteSetting.reqpm_default_country_code = ""
        expect(normalize(kind: "phone", value: "646-820-1413")[:value]).to eq("646-820-1413")
      end

      it "applies to phone-shaped Signal and Telegram values only" do
        expect(normalize(kind: "signal", value: "646 820 1413")[:value]).to eq("+1 646 820 1413")
        expect(normalize(kind: "telegram", value: "@jtech_user")[:value]).to eq("@jtech_user")
      end
    end

    it "rejects things that are not phone numbers" do
      expect(reason_for(kind: "phone", value: "call me")).to eq(%i[value phone])
      expect(reason_for(kind: "phone", value: "123")).to eq(%i[value phone])
      expect(reason_for(kind: "whatsapp", value: "1" * 16)).to eq(%i[value phone])
      expect(reason_for(kind: "sms", value: "")).to eq(%i[value blank])
    end
  end

  describe "email" do
    it "accepts a valid address" do
      expect(normalize(kind: "email", value: "me@example.com")[:value]).to eq("me@example.com")
    end

    it "rejects an invalid one" do
      expect(reason_for(kind: "email", value: "me at example")).to eq(%i[value email])
    end
  end

  describe "website" do
    it "adds https:// when the scheme is missing" do
      expect(normalize(kind: "website", value: "example.com/me")[:value]).to eq(
        "https://example.com/me",
      )
    end

    it "only allows http and https" do
      expect(reason_for(kind: "website", value: "javascript:alert(1)")).to eq(%i[value url])
      expect(reason_for(kind: "website", value: "ftp://example.com")).to eq(%i[value url])
      expect(reason_for(kind: "website", value: "data:text/html,hi")).to eq(%i[value url])
    end

    it "rejects credentials in the URL and hosts without a dot" do
      expect(reason_for(kind: "website", value: "https://user:pw@example.com")).to eq(%i[value url])
      expect(reason_for(kind: "website", value: "https://localhost")).to eq(%i[value url])
    end
  end

  describe "handles" do
    it "accepts usernames and phone numbers for telegram and signal" do
      expect(normalize(kind: "telegram", value: "@jtech_user")[:value]).to eq("@jtech_user")
      expect(normalize(kind: "signal", value: "+972 52 123 4567")[:value]).to eq("+972 52 123 4567")
      expect(normalize(kind: "discord", value: "someone#1234")[:value]).to eq("someone#1234")
    end

    it "accepts a username or a number for whatsapp" do
      expect(normalize(kind: "whatsapp", value: "@jtech.user")[:value]).to eq("@jtech.user")
      expect(normalize(kind: "whatsapp", value: "jtech_user2026")[:value]).to eq("jtech_user2026")
      expect(normalize(kind: "whatsapp", value: "646-820-1413")[:value]).to eq("+1 646-820-1413")
      expect(reason_for(kind: "whatsapp", value: "two words")).to eq(%i[value handle])
    end

    it "rejects spaces and markup" do
      expect(reason_for(kind: "discord", value: "<b>x</b>")).to eq(%i[value handle])
      expect(reason_for(kind: "telegram", value: "two words")).to eq(%i[value handle])
    end
  end

  describe "custom" do
    it "requires a label and keeps a known emoji" do
      result =
        normalize(kind: "custom", value: "Ask at the shul", label: "In person", emoji: ":wave:")
      expect(result).to include(label: "In person", emoji: "wave", value: "Ask at the shul")
      expect(reason_for(kind: "custom", value: "x", label: " ")).to eq(%i[label blank])
    end

    it "rejects an emoji Discourse doesn't have" do
      expect(reason_for(kind: "custom", value: "x", label: "y", emoji: "not_an_emoji_xyz")).to eq(
        %i[emoji unknown],
      )
    end

    it "ignores label and emoji on presets" do
      result = normalize(kind: "email", value: "a@b.co", label: "x", emoji: "wave")
      expect(result).to include(label: nil, emoji: nil)
    end
  end

  describe "text hygiene" do
    it "flattens newlines and trims" do
      expect(normalize(kind: "custom", value: "line one\nline two", label: "L")[:value]).to eq(
        "line one line two",
      )
    end

    it "rejects bidi overrides and zero-width characters" do
      expect(reason_for(kind: "custom", value: "abc‮def", label: "L")).to eq(
        %i[value invalid_characters],
      )
      expect(reason_for(kind: "custom", value: "a​b", label: "L")).to eq(
        %i[value invalid_characters],
      )
    end

    it "enforces lengths" do
      expect(reason_for(kind: "custom", value: "x" * 201, label: "L")).to eq(%i[value too_long])
      expect(reason_for(kind: "custom", value: "x", label: "L" * 31)).to eq(%i[label too_long])
      expect(reason_for(kind: "email", value: "a@b.co", note: "n" * 81)).to eq(%i[note too_long])
    end

    it "keeps a short note" do
      expect(normalize(kind: "phone", value: "0521234567", note: " evenings ")[:note]).to eq(
        "evenings",
      )
    end
  end
end
