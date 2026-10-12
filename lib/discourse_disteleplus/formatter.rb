# frozen_string_literal: true

module DiscourseDisteleplus
  # Pure text builders for both bridge directions. No I/O, no chat-plugin or
  # Telegram API knowledge — everything here is deterministic string work so
  # it can be unit-tested without stubs.
  #
  # Formatting is deliberately lossy in v1: Telegram entities are flattened
  # to plain text on the way in, and Discourse markdown travels as
  # HTML-escaped plain text (inside a bold author prefix) on the way out.
  # Entity ⇄ markdown conversion is future work.
  module Formatter
    # ── Telegram → Discourse ────────────────────────────────────────────────

    # Chat-message body for an inbound Telegram message. Matched senders post
    # as themselves, so their text passes through untouched; unmatched senders
    # are posted by the bridge bot with an author prefix.
    def self.inbound_text(msg, matched:)
      text = msg["text"] || msg["caption"] || ""
      matched ? text : prefixed(sender_display_name(msg["from"]), text)
    end

    def self.prefixed(display_name, text)
      "**#{display_name} (TG):** #{text}".strip
    end

    # Human-readable name for a Telegram User object: first + last name,
    # falling back to @username, falling back to the numeric id.
    def self.sender_display_name(from)
      from ||= {}
      name = [from["first_name"], from["last_name"]].compact_blank.join(" ")
      return name if name.present?
      return "@#{from["username"]}" if from["username"].present?
      "Telegram user #{from["id"]}"
    end

    # Markdown snapshot of a Telegram Poll object. Re-rendered (and the chat
    # message revised) whenever a `poll` state update arrives, so vote counts
    # stay best-effort fresh.
    def self.poll_markdown(poll)
      lines = ["📊 **Poll:** #{poll["question"]}"]
      total = poll["total_voter_count"].to_i

      Array(poll["options"]).each do |option|
        votes = option["voter_count"].to_i
        pct = total.positive? ? ((votes * 100.0) / total).round : 0
        lines << "- #{option["text"]} — #{votes} (#{pct}%)"
      end

      details = []
      details << "#{total} vote#{"s" if total != 1}"
      details << (poll["is_anonymous"] ? "anonymous" : "public votes")
      details << "closed" if poll["is_closed"]
      lines << "_#{details.join(" · ")}_"

      lines.join("\n")
    end

    # Placeholder for media we cannot bridge (over the size cap, download
    # failure, or an unportable type such as an animated sticker).
    def self.media_placeholder(type, size_bytes: nil)
      if size_bytes.to_i.positive?
        mb = (size_bytes.to_f / 1.megabyte).round(1)
        "📎 #{type} (#{mb} MB) — too large to bridge"
      else
        "📎 #{type} — could not be bridged"
      end
    end

    # ── Discourse → Telegram ────────────────────────────────────────────────

    # Telegram HTML-mode body for an outbound chat message. Always prefixed
    # with the Discourse author (bots cannot impersonate). HTML parse mode is
    # used because, unlike Markdown mode, stray underscores/asterisks in user
    # text cannot break it — everything user-supplied is escaped. Emoji
    # shortcodes (:grin: etc.) become real unicode so Telegram renders them.
    # Quote blocks collapse to a "↩︎ username" attribution (the quoted wall of
    # text — and whatever the user-card markup drags along — never crosses),
    # and common Discourse markdown (bold/italic/code/links) is converted to
    # the Telegram HTML entities instead of arriving as literal ** and [].
    # Legacy form: "<b>name:</b> text". With a profile URL the header becomes
    # a bold linked display name on its own line, which Telegram renders as
    # a proper author highlight.
    def self.outbound_html(username, text, display_name: nil, profile_url: nil)
      body = markdown_to_telegram_html(escape_html(emojify(collapse_quotes(text.to_s))))
      if profile_url.present?
        label = escape_html(display_name.presence || username)
        header = "<a href=\"#{escape_html(profile_url)}\"><b>#{label}</b></a>"
        return body.blank? ? header : "#{header}\n#{body}"
      end
      body.blank? ? "<b>#{escape_html(username)}</b>" : "<b>#{escape_html(username)}:</b> #{body}"
    end

    # [quote="Zev, post:3, topic:99, username:zev"]…[/quote] → "↩︎ zev".
    # The whole quoted body is dropped on purpose: Telegram renders it as an
    # unreadable blob (BBCode is not markdown), so only the attribution
    # survives. Innermost-first so nested quotes collapse cleanly.
    QUOTE_BLOCK = %r{\[quote(?:=("[^"\]]*"|[^\]]*))?\]((?:(?!\[quote).)*?)\[/quote\]}im

    def self.collapse_quotes(text)
      result = text.to_s
      while result.match?(QUOTE_BLOCK)
        result =
          result.gsub(QUOTE_BLOCK) do
            attribution = Regexp.last_match(1).to_s.delete('"')
            name = attribution.split(",").first.to_s.strip
            name = name.delete_prefix("username:").strip if name.start_with?("username:")
            (name.present? ? "↩︎ #{name}" : "↩︎").rstrip
          end
      end
      result
    end

    # Minimal Discourse-markdown → Telegram-HTML conversion, applied AFTER
    # HTML escaping so user text can never smuggle tags in. Deliberately
    # conservative: only unambiguous spans are converted; anything else stays
    # literal (Telegram rejects the whole message on malformed HTML).
    def self.markdown_to_telegram_html(escaped)
      html = escaped.to_s
      # Fenced code blocks first so nothing inside them is touched again.
      html = html.gsub(/```[a-z0-9_-]*\n?(.+?)\n?```/im) { "<pre>#{$1}</pre>" }
      html = html.gsub(/`([^`\n]+)`/) { "<code>#{$1}</code>" }
      # Inline uploads/images can't render in a text message — name them.
      html = html.gsub(%r{!\[([^\]]*)\]\(upload://[^)\s]+\)}) { $1.present? ? "📎 #{$1}" : "📎" }
      html =
        html.gsub(%r{\[([^\]]+)\]\((https?://[^)\s]+)\)}) do
          label = Regexp.last_match(1)
          url = Regexp.last_match(2).gsub('"', "%22")
          "<a href=\"#{url}\">#{label}</a>"
        end
      html = html.gsub(/\*\*([^*\n]+)\*\*/) { "<b>#{$1}</b>" }
      html = html.gsub(/(?<![\w*])\*([^*\s][^*\n]*?)\*(?![\w*])/) { "<i>#{$1}</i>" }
      html = html.gsub(/(?<![\w_])_([^_\s][^_\n]*?)_(?![\w_])/) { "<i>#{$1}</i>" }
      html.gsub(/~~([^~\n]+)~~/) { "<s>#{$1}</s>" }
    end

    # :grin: → 😁 via core's emoji db; guarded so the formatter stays usable
    # outside a full Discourse boot (pure-unit specs, console experiments).
    def self.emojify(text)
      return text unless defined?(::Emoji) && ::Emoji.respond_to?(:gsub_emoji_to_unicode)
      ::Emoji.gsub_emoji_to_unicode(text) || text
    end

    # For Telegram's HTML: text and double-quoted attributes alike. The
    # one escaper every Telegram message goes through.
    def self.escape_html(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end
