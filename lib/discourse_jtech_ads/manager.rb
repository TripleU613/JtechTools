# frozen_string_literal: true

module ::DiscourseJtechAds
  # Managing the ads from code: the MCP tools and the admin preview use it.
  # Every change goes through the setting itself (validated by its schema
  # and logged as a staff action), exactly as if made in the editor.
  module Manager
    SETTINGS = {
      "enabled" => :jtech_ads_enabled,
      "rotate_seconds" => :jtech_ads_rotate_seconds,
      "welcome_seconds" => :jtech_ads_welcome_seconds,
      "new_visitor_seconds" => :jtech_ads_new_visitor_seconds,
      "label" => :jtech_ads_label,
    }.freeze
    FIELDS = %w[
      name
      enabled
      headline
      text
      card
      css
      house
      intro
      audience
      groups
      weight
      starts_at
      ends_at
    ].freeze
    PREVIEW_TTL = 1.hour

    class Error < StandardError
    end

    class << self
      def settings
        SETTINGS.to_h { |key, name| [key, SiteSetting.get(name)] }
      end

      # Every ad as stored, paused ones too, with its thumbs
      def entries
        list = raw
        counts = Vote.counts(list.map { DiscourseJtechAds.key_for(it["name"]) })
        list.map do |entry|
          key = DiscourseJtechAds.key_for(entry["name"])
          entry.merge("key" => key, "thumbs" => counts[key] || { up: 0, down: 0 })
        end
      end

      def configure!(changes, by:)
        changes.each do |key, value|
          name = SETTINGS[key.to_s] or raise Error, "Unknown setting: #{key}"
          SiteSetting.set_and_log(name, value, by)
        end
        settings
      end

      # Creates the ad, or replaces the one with the same name
      def save!(entry, by:)
        entry = normalize(entry)
        list = raw.reject { it["name"] == entry["name"] }
        position = raw.index { it["name"] == entry["name"] } || list.size
        list.insert(position, entry)
        write!(list, by:)
        entry
      end

      def delete!(name, by:)
        list = raw
        raise Error, "No ad named #{name}" if list.none? { it["name"] == name }
        write!(list.reject { it["name"] == name }, by:)
      end

      # What the cleaning keeps and drops, so a writer (or an agent) sees
      # why something didn't come through
      def report(entry)
        entry = normalize(entry)
        css, refused = App.clean_css(entry["css"])
        if css
          card, dropped = App.clean_html(entry["card"])
          kind = "app"
        else
          card = DiscourseJtechAds.clean_card(entry["card"])
          dropped = dropped(entry["card"])
          kind = entry["card"].present? ? "kit card" : "headline and text"
        end
        dropped += dropped(entry["headline"], card: false) + dropped(entry["text"], card: false)
        dropped << refused if refused
        {
          kind:,
          headline: DiscourseJtechAds.clean(entry["headline"]),
          text: DiscourseJtechAds.clean(entry["text"]),
          card: card.presence,
          css:,
          dropped: dropped.uniq,
        }
      end

      # A preview kept for an hour: a saved ad by name, or a draft that
      # isn't saved. Only admins can open it, and nothing else changes.
      def preview!(entry: nil, name: nil)
        entry = raw.find { it["name"] == name } or raise Error, "No ad named #{name}" if name
        entry = normalize(entry.merge("enabled" => true))
        token = SecureRandom.hex(12)
        Discourse.redis.setex(redis_key(token), PREVIEW_TTL.to_i, entry.to_json)
        path = "/latest?jl_preview=#{token}"
        { token:, path:, url: "#{Discourse.base_url}#{path}" }
      end

      def preview_line(token)
        return nil if !token.to_s.match?(/\A[0-9a-f]{24}\z/)

        stored = Discourse.redis.get(redis_key(token)) or return nil
        entry = JSON.parse(stored)
        made = DiscourseJtechAds.card_and_css(entry)
        {
          k: DiscourseJtechAds.key_for(entry["name"]),
          h: DiscourseJtechAds.clean(entry["headline"]),
          t: DiscourseJtechAds.clean(entry["text"]),
          c: made[:card].presence,
          x: made[:css],
          o: entry["house"] == true || nil,
          w: 1,
          preview: true,
        }
      end

      private

      def raw
        value = SiteSetting.jtech_ads_list
        list = value.is_a?(String) ? JSON.parse(value.presence || "[]") : Array(value)
        list.map { it.to_h.stringify_keys }
      end

      def write!(list, by:)
        SiteSetting.set_and_log(:jtech_ads_list, list.to_json, by)
      rescue Discourse::InvalidParameters, ArgumentError => e
        raise Error, e.message
      end

      def normalize(entry)
        entry = entry.to_h.stringify_keys.slice(*FIELDS)
        raise Error, "An ad needs a name" if entry["name"].blank?
        raise Error, "An ad needs a headline" if entry["headline"].blank?

        { "enabled" => true, "audience" => "everyone", "groups" => [], "weight" => 1 }.merge(
          entry.compact,
        )
      end

      def dropped(html, card: true)
        return [] if html.blank?

        tags = card ? CARD_TAGS : TAGS
        Nokogiri::HTML5
          .fragment(html.to_s)
          .css("*")
          .flat_map do |node|
            notes = []
            notes << "<#{node.name}>" if tags.exclude?(node.name)
            if card && node["class"]
              notes.concat((node["class"].split - KIT).map { "class #{it}" })
            elsif node["class"]
              notes << "class (headline and text take none)"
            end
            notes.concat(
              node
                .attributes
                .keys
                .reject { %w[href title class dir].include?(it) }
                .map { "attribute #{it}" },
            )
            notes
          end
      end

      def redis_key(token)
        "jtech_ads_preview:#{token}"
      end
    end
  end
end
