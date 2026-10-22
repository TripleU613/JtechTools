# frozen_string_literal: true

module DiscourseReqpm
  # The ways to reach someone. Presets have a fixed icon and a format the
  # value is checked against; "custom" lets the user name their own and pick
  # an emoji for it. The client mirrors this list in lib/reqpm-kinds.js for
  # icons, input types and links; the server is the only place values are
  # validated.
  module Kinds
    CUSTOM = "custom"

    # kind => value format. Order is the order the picker shows them in.
    PRESETS = {
      "phone" => :phone,
      "sms" => :phone,
      "whatsapp" => :handle_or_phone,
      "email" => :email,
      "website" => :url,
      "telegram" => :handle_or_phone,
      "signal" => :handle_or_phone,
      "discord" => :handle,
    }.freeze

    ALL = (PRESETS.keys + [CUSTOM]).freeze

    MAX_VALUE_LENGTH = 200
    MAX_LABEL_LENGTH = 30
    MAX_NOTE_LENGTH = 80
    MAX_URL_LENGTH = 300

    PHONE_CHARS = /\A\+?[0-9(][0-9 ().\-]*\z/
    HANDLE = /\A@?[A-Za-z0-9_.\-]{2,40}(#\d{4})?\z/
    # C0/C1 controls, bidi overrides and zero-width characters: nothing a
    # contact detail needs, and the usual tools for making a value display
    # as something other than what it is.
    UNSAFE_CHARS = /[\p{Cc}​-‏‪-‮⁦-⁩﻿]/

    class Invalid < StandardError
      attr_reader :field, :reason

      def initialize(field, reason)
        @field = field
        @reason = reason
        super("#{field}: #{reason}")
      end
    end

    def self.valid?(kind)
      ALL.include?(kind.to_s)
    end

    # Returns a hash of the cleaned attributes, or raises Invalid naming the
    # field and the reason (an i18n key suffix).
    def self.normalize!(kind:, value:, label: nil, emoji: nil, note: nil)
      kind = kind.to_s
      raise Invalid.new(:kind, :unknown) unless valid?(kind)

      cleaned = { kind: kind, value: normalize_value!(kind, value), note: clean_note!(note) }

      if kind == CUSTOM
        cleaned[:label] = clean_text!(:label, label, MAX_LABEL_LENGTH)
        raise Invalid.new(:label, :blank) if cleaned[:label].blank?
        cleaned[:emoji] = clean_emoji!(emoji)
      else
        cleaned[:label] = nil
        cleaned[:emoji] = nil
      end

      cleaned
    end

    def self.normalize_value!(kind, value)
      text = clean_text!(:value, value, MAX_VALUE_LENGTH)
      raise Invalid.new(:value, :blank) if text.blank?

      case PRESETS[kind]
      when :phone
        phone!(text)
      when :email
        email!(text)
      when :url
        url!(text)
      when :handle
        handle!(text)
      when :handle_or_phone
        looks_like_phone?(text) ? phone!(text) : handle!(text)
      else
        text
      end
    end

    def self.looks_like_phone?(text)
      text.match?(PHONE_CHARS) && text.count("0-9") >= 5
    end

    def self.phone!(text)
      digits = text.count("0-9")
      raise Invalid.new(:value, :phone) if !text.match?(PHONE_CHARS) || !digits.between?(5, 15)
      with_country_code(text.squeeze(" "))
    end

    # A number typed without a country code gets the forum's default one
    # (reqpm_default_country_code, "1" out of the box), so "646-820-1413"
    # is stored as "+1 646-820-1413" — otherwise WhatsApp and friends read
    # the leading digits as a country ("64" → New Zealand).
    #
    # "00…" is the international prefix and becomes "+". Numbers starting
    # with 0 are local formats elsewhere (e.g. 052-…), and anything that is
    # not a plain 10-digit national number is left alone rather than guessed.
    def self.with_country_code(text)
      return text if text.start_with?("+")
      return "+#{text.delete_prefix("00").lstrip}" if text.start_with?("00")

      code = SiteSetting.reqpm_default_country_code.to_s.delete("^0-9")
      digits = text.delete("^0-9")
      return text if code.empty? || digits.start_with?("0")
      return "+#{code} #{text}" if digits.length == 10
      return "+#{text}" if digits.start_with?(code) && digits.length == 10 + code.length
      text
    end

    def self.email!(text)
      raise Invalid.new(:value, :email) if text.length > 254
      raise Invalid.new(:value, :email) unless EmailAddressValidator.valid_value?(text)
      text
    end

    def self.url!(text)
      candidate = text.match?(%r{\A[a-z][a-z0-9+.\-]*://}i) ? text : "https://#{text}"
      raise Invalid.new(:value, :url) if candidate.length > MAX_URL_LENGTH || candidate.match?(/\s/)

      uri = URI.parse(candidate)
      unless %w[http https].include?(uri.scheme&.downcase) && uri.host.present? &&
               uri.host.include?(".") && uri.userinfo.nil?
        raise Invalid.new(:value, :url)
      end
      uri.to_s
    rescue URI::InvalidURIError
      raise Invalid.new(:value, :url)
    end

    def self.handle!(text)
      raise Invalid.new(:value, :handle) unless text.match?(HANDLE)
      text
    end

    def self.clean_note!(note)
      text = clean_text!(:note, note, MAX_NOTE_LENGTH)
      text.presence
    end

    def self.clean_emoji!(emoji)
      name = emoji.to_s.strip.delete_prefix(":").delete_suffix(":")
      return nil if name.blank?
      raise Invalid.new(:emoji, :unknown) if name.length > 100 || !Emoji.exists?(name)
      name
    end

    # Single line, trimmed, no control or invisible formatting characters.
    def self.clean_text!(field, raw, max)
      return "" if raw.nil?
      text = raw.to_s.unicode_normalize(:nfc).gsub(/[\r\n\t]+/, " ").strip
      raise Invalid.new(field, :invalid_characters) if text.match?(UNSAFE_CHARS)
      raise Invalid.new(field, :too_long) if text.length > max
      text
    rescue ArgumentError, Encoding::CompatibilityError
      raise Invalid.new(field, :invalid_characters)
    end
  end
end
