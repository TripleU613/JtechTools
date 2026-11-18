# frozen_string_literal: true

# Ads in the welcome area at the top of the home page (docs/features/ads.md).
#
# The ads are one list setting (jtech_ads_list): admins add, edit, pause and
# schedule them in the setting's own editor. Each viewer gets the ads meant
# for them inside the page's preloaded site data, so there is no request,
# asset or URL of the ads' own for a blocker to match. Nothing the browser
# sees is named after ads (see "Naming" in the docs).
#
# Ads are text and links only: what admins type is cleaned to inline tags on
# the way out, so no image, video, script or style gets through, and an ad
# always takes the theme's own look.
module ::DiscourseJtechAds
  VOTE_VALUES = [-1, 1].freeze
  AUDIENCES = %w[everyone visitors members groups].freeze
  TAGS = %w[a b strong i em u s small mark code br span sub sup].freeze
  KEY_FORMAT = /\A[0-9a-f]{12}\z/

  Ad =
    Struct.new(
      :key,
      :headline,
      :text,
      :audience,
      :group_ids,
      :weight,
      :starts_at,
      :ends_at,
      keyword_init: true,
    )

  class << self
    def enabled?
      SiteSetting.jtech_enabled && SiteSetting.jtech_ads_enabled
    end

    # Every running ad, cleaned. Parsed once per value of the setting.
    def all
      raw = SiteSetting.jtech_ads_list
      return @all if @all_raw == raw

      @all = parse(raw)
      @all_raw = raw
      @all
    end

    # The ads this viewer may see. Ones not started yet are included (the
    # browser waits for their start), so a cached page can't miss one; ones
    # that have ended are not.
    def visible_to(guardian)
      user = guardian&.user
      group_ids = nil
      now = Time.zone.now

      all.select do |ad|
        next false if ad.ends_at && ad.ends_at <= now

        case ad.audience
        when "visitors"
          user.nil?
        when "members"
          user.present?
        when "groups"
          next false if user.nil? || ad.group_ids.empty?
          group_ids ||=
            GroupUser.where(user_id: user.id).pluck(:group_id).to_set << Group::AUTO_GROUPS[
              :everyone
            ]
          ad.group_ids.any? { group_ids.include?(it) }
        else
          true
        end
      end
    end

    def visible?(guardian, key)
      visible_to(guardian).any? { it.key == key }
    end

    def key_for(name)
      Digest::SHA256.hexdigest("jtech-ad:#{name}")[0, 12]
    end

    # What the site serializer sends. Short, neutral keys on purpose.
    def payload(guardian)
      ads = visible_to(guardian)
      user = guardian&.user
      keys = ads.map(&:key)

      mine =
        if user && keys.present?
          Vote.where(user_id: user.id, ad_key: keys).pluck(:ad_key, :value).to_h
        else
          {}
        end
      counts = guardian&.is_staff? && keys.present? ? Vote.counts(keys) : {}

      {
        label: SiteSetting.jtech_ads_label,
        every: SiteSetting.jtech_ads_rotate_seconds,
        items:
          ads.map do |ad|
            item = {
              k: ad.key,
              h: ad.headline,
              t: ad.text,
              w: ad.weight,
              s: ad.starts_at&.iso8601,
              e: ad.ends_at&.iso8601,
            }
            item[:v] = mine[ad.key] if user
            item[:n] = counts[ad.key] || { up: 0, down: 0 } if guardian&.is_staff?
            item
          end,
      }
    end

    # The admin-typed HTML, down to inline text tags and safe links.
    def clean(html)
      return "" if html.blank?

      # Tags that carry content of their own (script, style, iframe…) go
      # with their content; the allowlist then strips the rest to their text
      pruned = Loofah.html5_fragment(html.to_s).scrub!(:prune).to_s
      sanitized =
        Rails::Html::SafeListSanitizer.new.sanitize(pruned, tags: TAGS, attributes: %w[href title])
      fragment = Nokogiri::HTML5.fragment(sanitized)
      fragment
        .css("a")
        .each do |link|
          href = link["href"].to_s.strip
          if safe_href?(href)
            link["rel"] = "nofollow noopener"
            link["target"] = "_blank" if href.match?(%r{\A(https?:)?//}i)
          else
            link.remove_attribute("href")
          end
        end
      fragment.to_html
    end

    def clear_cache!
      @all_raw = nil
      Site.clear_anon_cache!
    end

    private

    def parse(raw)
      list = raw.is_a?(String) ? JSON.parse(raw.presence || "[]") : Array(raw)
      list.filter_map do |entry|
        entry = entry.to_h.stringify_keys
        next if entry["enabled"] == false || entry["name"].blank?

        headline = clean(entry["headline"])
        next if headline.blank?

        audience = entry["audience"].to_s
        Ad.new(
          key: key_for(entry["name"]),
          headline: headline,
          text: clean(entry["text"]),
          audience: AUDIENCES.include?(audience) ? audience : "everyone",
          group_ids: Array(entry["groups"]).map(&:to_i),
          weight: entry["weight"].to_i.clamp(1, 10),
          starts_at: time(entry["starts_at"]),
          ends_at: time(entry["ends_at"]),
        )
      end
    rescue JSON::ParserError
      []
    end

    def time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def safe_href?(href)
      href.start_with?("/") || href.match?(%r{\A(https?:)?//}i) || href.start_with?("mailto:")
    end
  end
end
