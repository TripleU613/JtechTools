# frozen_string_literal: true

module DiscourseDiscordMirror
  # Turns a forum post into Discord webhook messages: the author's name and
  # avatar, the post as Discord markdown, and a footer linking back with the
  # original date (Discord can't backdate a message).
  module Renderer
    module_function

    MESSAGE_LIMIT = 2000
    MAX_PARTS = 4
    THREAD_NAME_LIMIT = 100
    USERNAME_LIMIT = 80

    def thread_name(topic)
      topic.title.to_s.squish.truncate(THREAD_NAME_LIMIT).presence || "Topic #{topic.id}"
    end

    # Discord refuses webhook names containing "discord" or "clyde".
    def username(user)
      name = user.username.to_s.gsub(/discord/i, "d1scord").gsub(/clyde/i, "clyd3")
      name = name.truncate(USERNAME_LIMIT)
      name.presence || "JTech member"
    end

    def avatar_url(user)
      url = user.avatar_template_url.to_s.gsub("{size}", "128")
      url.start_with?("//") ? "https:#{url}" : url
    end

    def parts(post)
      footer = footer(post)
      room = MESSAGE_LIMIT - footer.length - 2
      chunks = chunk(body(post), room)

      if chunks.length > MAX_PARTS
        chunks = chunks.first(MAX_PARTS)
        chunks[-1] = "#{chunks[-1].truncate(room - 40)}\n…"
        footer = footer(post, truncated: true)
      end

      chunks = [""] if chunks.empty?
      chunks.each_with_index.map do |text, index|
        index == chunks.length - 1 ? [text, footer].compact_blank.join("\n\n") : text
      end
    end

    def body(post)
      html = PrettyText.format_for_email(post.cooked.to_s, post)
      markdown = HtmlToMarkdown.new(html).to_markdown
      # Discord shows a bare image link as the image; ![alt](url) as text.
      markdown.gsub(/!\[[^\]]*\]\(([^)\s]+)[^)]*\)/) { $1 }
    end

    def footer(post, truncated: false)
      label = truncated ? "Read the whole post on JTech Forums" : "JTech Forums"
      "-# [#{label}](<#{post.full_url}>) · <t:#{post.created_at.to_i}:f>"
    end

    # Splits on paragraph breaks, then on lines, then hard-cuts, so a part
    # never goes over the limit.
    def chunk(text, room)
      text = text.to_s.strip
      return [] if text.empty?

      chunks = []
      current = +""
      text
        .split(/(\n\n)/)
        .each do |piece|
          if current.length + piece.length <= room
            current << piece
            next
          end
          chunks << current.strip if current.strip.present?
          current = +""
          while piece.length > room
            cut = piece.rindex("\n", room) || piece.rindex(" ", room) || room
            cut = room if cut <= 0
            chunks << piece[0...cut].strip
            piece = piece[cut..].to_s
          end
          current << piece
        end
      chunks << current.strip if current.strip.present?
      chunks
    end

    def digest(content, username, avatar)
      Digest::SHA1.hexdigest([content, username, avatar].join("\u0000"))
    end
  end
end
