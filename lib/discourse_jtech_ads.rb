# frozen_string_literal: true

# Ads in the welcome area at the top of the home page (docs/features/ads.md).
#
# The ads are one list setting (jtech_ads_list): admins add, edit, pause and
# schedule them in the setting's own editor. Each viewer gets the ads meant
# for them inside the page's preloaded site data, so there is no request,
# asset or URL of the ads' own for a blocker to match. Nothing the browser
# sees is named after ads (see "Naming" in the docs).
#
# Ads are text and links only. A simple ad is a headline and a line, cleaned
# to inline tags. An ad can instead fill the whole card ("card"): HTML built
# from block tags and the kit's classes (KIT, styled in lines.scss from the
# theme's variables), so it can be laid out like a small page yet still
# takes every theme's and palette's look. No image, video, script, style,
# form or id gets through either way.
module ::DiscourseJtechAds
  VOTE_VALUES = [-1, 1].freeze
  AUDIENCES = %w[everyone visitors members groups].freeze
  TAGS = %w[a b strong i em u s small mark code br span sub sup].freeze
  CARD_TAGS = (TAGS + %w[div section header footer h2 h3 h4 p ul ol li blockquote hr kbd]).freeze
  # The only classes a card may use: the kit's (assets/stylesheets/lines.scss,
  # docs/features/ads.md). Exact names, not a prefix.
  KIT = %w[
    jl-split
    jl-row
    jl-stack
    jl-grid
    jl-center
    jl-end
    jl-spacer
    jl-kicker
    jl-title
    jl-title-xl
    jl-lead
    jl-text
    jl-muted
    jl-small
    jl-mono
    jl-accent
    jl-panel
    jl-glow
    jl-stat
    jl-stat-label
    jl-chips
    jl-chip
    jl-list
    jl-quote
    jl-big
    jl-button
    jl-button-alt
    jl-float
    jl-pulse
    jl-marquee
  ].freeze
  KEY_FORMAT = /\A[0-9a-f]{12}\z/

  Ad =
    Struct.new(
      :key,
      :headline,
      :text,
      :card,
      :css,
      :house,
      :intro,
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

      {
        label: SiteSetting.jtech_ads_label,
        every: SiteSetting.jtech_ads_rotate_seconds,
        intro: SiteSetting.jtech_ads_welcome_seconds,
        fresh: SiteSetting.jtech_ads_new_visitor_seconds,
        items:
          ads.map do |ad|
            item = {
              k: ad.key,
              h: ad.headline,
              t: ad.text,
              c: ad.card.presence,
              x: ad.css,
              o: ad.house || nil,
              i: ad.intro || nil,
              w: ad.weight,
              s: ad.starts_at&.iso8601,
              e: ad.ends_at&.iso8601,
            }
            item[:v] = mine[ad.key] if user
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
      safe_links(fragment)
      fragment.to_html
    end

    # A full-card ad's HTML: block and inline tags, the kit's classes only
    def clean_card(html)
      return "" if html.blank?

      pruned = Loofah.html5_fragment(html.to_s).scrub!(:prune).to_s
      sanitized =
        Rails::Html::SafeListSanitizer.new.sanitize(
          pruned,
          tags: CARD_TAGS,
          attributes: %w[href title class dir],
        )
      fragment = Nokogiri::HTML5.fragment(sanitized)
      fragment
        .css("[class]")
        .each do |node|
          kept = node["class"].split & KIT
          kept.empty? ? node.remove_attribute("class") : node["class"] = kept.join(" ")
        end
      fragment
        .css("[dir]")
        .each { |node| node.remove_attribute("dir") if %w[ltr rtl auto].exclude?(node["dir"]) }
      safe_links(fragment)
      fragment.to_html
    end

    # An app (card with CSS of its own) is cleaned as an app: free classes
    # and safe SVG, run in a shadow root. CSS that's refused leaves the card
    # cleaned as a kit card instead.
    def card_and_css(entry)
      css, = App.clean_css(entry["css"])
      if css
        { card: App.clean_html(entry["card"]).first, css: }
      else
        { card: clean_card(entry["card"]), css: nil }
      end
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
          **card_and_css(entry),
          house: entry["house"] == true,
          intro: entry["intro"] == true,
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

    def safe_links(fragment)
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
    end

    def safe_href?(href)
      href.start_with?("/") || href.match?(%r{\A(https?:)?//}i) || href.start_with?("mailto:")
    end
  end
end
