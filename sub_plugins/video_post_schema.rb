# frozen_string_literal: true
# Jtech sub-plugin: an image in the search data of topics that open with only
# videos (lib/discourse_video_post_schema.rb). Loaded by Jtech/plugin.rb in the
# Plugin::Instance context.

require_relative "../lib/discourse_video_post_schema"

after_initialize do
  # Rendered inside the topic's DiscussionForumPosting, before the posts
  register_html_builder("server:topic-show-before-posts") do |_controller, topic_view: nil, **|
    DiscourseVideoPostSchema.html(topic_view)
  end
end
