# frozen_string_literal: true

module DiscourseDisteleplus
  module ForumUploadFormatter
    # Media captions are limited to 1024 visible characters by Telegram.
    # Leave room for a maximum-length filename/topic/username plus metadata.
    MAX_COMMENT_CHARS = 100

    def self.caption(post, upload)
      filename = upload.original_filename.presence || upload.url.to_s.split("/").last || "upload"
      title = escape(filename)
      topic_title = escape(post.topic.title)
      author = escape(post.user&.username || "unknown")
      comment = escape(comment_for(post))
      url = escape(post.full_url)
      time = post.created_at.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
      size = "#{upload.filesize.to_i} bytes (#{human_size(upload.filesize)})"
      sha1 = upload.sha1.to_s.downcase

      details = []
      details << hashtags(post, upload)
      details << "💬 #{comment}" if comment.present?
      details << "👤 #{author}"
      details << "🕒 #{time}"
      details << "📦 #{escape(size)}"
      details << "🔎 SHA-1 <code>#{escape(sha1)}</code>" if sha1.present?
      details << "🔗 <a href=\"#{url}\">#{topic_title} · post ##{post.post_number}</a>"

      "<b>#{title}</b>\n<blockquote expandable>#{details.join("\n")}</blockquote>"
    end

    def self.comment_for(post)
      text = post.excerpt(MAX_COMMENT_CHARS, strip_links: true, strip_images: true).to_s
      text.gsub(/\s+/, " ").strip
    rescue StandardError
      post.raw.to_s.gsub(/\s+/, " ").strip.truncate(MAX_COMMENT_CHARS)
    end

    def self.human_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i, precision: 3)
    end

    def self.hashtags(post, upload)
      tags = ["#jtechupload"]
      tags << hashtag(upload.extension, "file")
      tags << hashtag(post.topic.category&.slug, "cat")
      tags << hashtag(upload.sha1.to_s.first(10), "jtu")
      tags.compact.join(" ")
    end

    def self.hashtag(value, prefix)
      normalized =
        I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      return nil if normalized.blank?
      "##{prefix}_#{normalized.first(48)}"
    end

    def self.escape(value)
      Formatter.escape_html(value)
    end
  end
end
