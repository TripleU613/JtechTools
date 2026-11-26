# frozen_string_literal: true

# The crawler view of a topic marks the first post up as the
# DiscussionForumPosting's text. An uploaded video is cooked into a
# .video-placeholder-container div that the browser turns into a player, so a
# first post that is only videos gives the item no text, no image and no video,
# and Google rejects it. Core already links Post#image_url as the image, but a
# video's thumbnail never becomes one, so we link the first thumbnail instead.
module DiscourseVideoPostSchema
  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_video_post_schema_image
  end

  def self.image_url(post)
    return if post.nil? || post.hidden || post.image_url.present? || post.cooked.blank?
    return unless post.cooked.include?("video-placeholder-container")

    Nokogiri::HTML5
      .fragment(post.cooked)
      .css(".video-placeholder-container[data-thumbnail-src]")
      .map { |video| video["data-thumbnail-src"] }
      .find { |src| src.match?(%r{\Ahttps?://}i) }
  end

  def self.html(topic_view)
    return "" if !enabled? || topic_view.nil?
    url = image_url(topic_view.topic.first_post)
    url ? "<link itemprop=\"image\" href=\"#{ERB::Util.html_escape(url)}\">" : ""
  end
end
