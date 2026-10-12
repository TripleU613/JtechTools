# frozen_string_literal: true

module ::DiscourseListingFormat
  # Says what's wrong with a post's text, as messages for the person
  # posting. An empty list means it may be saved.
  class Checker
    ALLOWED_SCHEMES = %w[mailto tel sms].freeze

    # A topic's address with a slug: /t/some-slug/32 or /t/some-slug/32/232.
    # The slug has to contain a non-digit, or /t/32/232 would read as 232.
    TOPIC_URL = %r{/t/(?:[^/?#]*[^\d/?#][^/?#]*/)?(\d+)}

    # Markdown that can sit around a field's name without changing it:
    # list bullets, headings, bold and italics.
    LEADING_MARKUP = /\A(?:\s*(?:[-*+]|\d+[.)]|#+)\s+)?/
    EMPHASIS = /[*_~]+/

    # Web addresses typed as plain text ("ebay.com/itm/123"), which the
    # forum doesn't turn into links but are still a way off the forum. Only
    # common endings, so "v2.0" or "node.js" aren't taken for one; the
    # lookbehind leaves email addresses alone.
    BARE_DOMAIN =
      /(?<![@\w.\-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|net|org|co|io|me|us|uk|ca|il|biz|info|shop|store|app|ly|gl|to|link))(?![\w-])/i

    # Admins can paste a topic's address instead of its number.
    def self.topic_ids
      SiteSetting
        .listing_format_topics_map
        .filter_map do |entry|
          entry = entry.strip
          id = entry.match?(/\A\d+\z/) ? entry : entry[TOPIC_URL, 1]
          id&.to_i
        end
        .uniq
    end

    def self.fields
      SiteSetting.listing_format_fields_map.map(&:strip).reject(&:empty?).uniq
    end

    # Sections that may be left empty, such as the pictures.
    def self.optional_fields
      optional = SiteSetting.listing_format_optional_fields_map.map(&:strip)
      fields.select { |field| optional.any? { |name| name.casecmp?(field) } }
    end

    # { "CONDITION" => { multiple: false, options: ["New", …], details: [] } }.
    # An option written with a trailing * ("Pickup*") needs details with it
    # (where to pick up). Entries naming a section that isn't a field are
    # dropped.
    def self.choices
      names = fields
      result = {}
      {
        false => SiteSetting.listing_format_single_choice_map,
        true => SiteSetting.listing_format_multiple_choice_map,
      }.each do |multiple, entries|
        entries.each do |entry|
          name, options = entry.split(":", 2)
          field = names.find { |f| f.casecmp?(name.to_s.strip) }
          options = options.to_s.split(",").map(&:strip).reject(&:empty?).uniq
          details = options.select { |o| o.end_with?("*") }.map { |o| o.delete_suffix("*").strip }
          options = options.map { |o| o.delete_suffix("*").strip }.uniq
          if field && options.any?
            result[field] = { multiple: multiple, options: options, details: details }
          end
        end
      end
      result
    end

    def self.editor_field
      name = SiteSetting.listing_format_editor_field.to_s.strip
      fields.find { |field| field.casecmp?(name) }
    end

    # `previous` is the text before an edit, nil for a new post.
    def initialize(raw, previous: nil, topic_id: nil)
      @raw = raw.to_s
      @previous = previous
      @topic_id = topic_id
    end

    def problems
      [missing_fields_problem, *missing_details_problems, links_problem].compact
    end

    # [field, option] pairs where a section names an option that needs
    # details ("Pickup") and says nothing else. An older post that already
    # lacked them can still be edited.
    def missing_details
      now = self.class.missing_details_in(@raw)
      return now if @previous.nil? || now.empty?
      self.class.missing_details_in(@previous).empty? ? now : []
    end

    def self.missing_details_in(raw)
      texts = section_texts(raw)
      choices.flat_map do |field, choice|
        next [] if choice[:details].blank? || !texts.key?(field)
        tokens = texts[field].join("\n").split(/[,\n]/).map(&:strip).reject(&:empty?)
        known = choice[:options].map(&:downcase)
        next [] if tokens.any? { |token| !known.include?(token.downcase) }
        choice[:details]
          .select { |option| tokens.any? { |token| token.casecmp?(option) } }
          .map { |option| [field, option] }
      end
    end

    def missing_fields
      missing = self.class.missing_fields_in(@raw)
      # An older post only has to keep the fields it already had.
      missing &= self.class.fields - self.class.missing_fields_in(@previous) if @previous
      missing
    end

    def outside_links
      links = outside_links_in(@raw)
      links -= outside_links_in(@previous) if @previous
      links
    end

    # A field counts when its name starts a line, as a heading ("### ITEM"),
    # in bold or before a colon ("Item: …"), and something is written after
    # it: on the same line, or under it before the next field.
    def self.missing_fields_in(raw)
      texts = section_texts(raw)
      # Every section is still read, so an empty optional one doesn't swallow
      # the lines after it; only the required ones can be missing.
      optional = optional_fields
      fields.reject { |field| texts[field].present? || optional.include?(field) }
    end

    # { field => [lines written for it] }, the same-line text included.
    def self.section_texts(raw)
      names = fields
      texts = {}
      current = nil
      strip_quotes(raw.to_s).each_line do |line|
        text = line.sub(LEADING_MARKUP, "").gsub(EMPHASIS, "").strip
        field, rest = field_line(text, names)
        if field
          current = field
          texts[current] ||= []
          texts[current] << rest if rest.present?
        elsif current && text.present?
          texts[current] << text
        end
      end
      texts
    end

    # Longest first, so a field whose name starts with another's is found.
    def self.field_line(text, names)
      names
        .sort_by { |field| -field.length }
        .each do |field|
          match = text.match(/\A#{Regexp.escape(field)}\s*(?:(?::|-|–|—)\s*(.*))?\z/i)
          return field, match[1].to_s if match
        end
      nil
    end

    # Quoted posts are someone else's words; their fields don't count.
    def self.strip_quotes(raw)
      text = raw.dup
      # Innermost first, so nested quotes come out whole.
      while text.sub!(%r{\[quote(?:=[^\]]*)?\](?:(?!\[quote).)*?\[/quote\]}im, "")
      end
      text.lines.reject { |line| line.lstrip.start_with?(">") }.join
    end

    private

    def missing_details_problems
      missing_details.map do |field, option|
        I18n.t("listing_format.errors.missing_details", field: field, option: option)
      end
    end

    def missing_fields_problem
      missing = missing_fields
      return if missing.empty?

      I18n.t(
        "listing_format.errors.missing_fields",
        fields: missing.join(", "),
        example: "### #{missing.first}",
      )
    end

    def links_problem
      return unless SiteSetting.listing_format_block_links
      links = outside_links
      return if links.empty?

      I18n.t("listing_format.errors.outside_links", links: links.first(3).join(", "))
    end

    # Links are read from the cooked post, so bare URLs, oneboxes,
    # [text](url) and <a> tags all count, quotes included.
    def outside_links_in(raw)
      return [] if raw.blank?
      fragment = Nokogiri::HTML5.fragment(PrettyText.cook(raw, topic_id: @topic_id))
      anchors = fragment.css("a")

      linked =
        anchors
          .map { |a| a["href"].to_s.strip }
          .reject { |href| allowed?(href) }
          .map { |href| display(href) }

      anchors.remove
      typed =
        fragment.text.scan(BARE_DOMAIN).flatten.map(&:downcase).reject { |host| forum_host?(host) }

      (linked + typed).uniq
    end

    def allowed?(href)
      return true if href.empty? || href.start_with?("#")
      return true if href.start_with?("/") && !href.start_with?("//")

      uri = URI.parse(href)
      return ALLOWED_SCHEMES.include?(uri.scheme.downcase) if uri.scheme && uri.host.nil?
      return true if uri.host.nil? && uri.scheme.nil?

      forum_host?(uri.host) || UrlHelper.is_local(href)
    rescue URI::Error
      false
    end

    def forum_host?(host)
      host = host.to_s.downcase
      [Discourse.current_hostname, GlobalSetting.hostname].compact.map(&:downcase).include?(host)
    end

    def display(href)
      URI.parse(href).host.presence || href
    rescue URI::Error
      href
    end
  end
end
