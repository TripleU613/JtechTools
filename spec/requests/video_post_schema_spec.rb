# frozen_string_literal: true

require "rails_helper"

# A topic whose first post is only videos gets the first video's thumbnail as
# its image in the crawler view, so search engines see a valid
# DiscussionForumPosting.
RSpec.describe "Image for video-only topics in the crawler view" do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  let(:thumbnail) { "#{Discourse.base_url}/uploads/default/original/1X/thumb.png" }
  let(:image_link) { %(<link itemprop="image" href="#{thumbnail}">) }

  before { SiteSetting.jtech_enabled = true }

  def video(thumbnail_src)
    <<~HTML
      <p></p><div class="video-placeholder-container" data-video-src="/uploads/default/original/1X/v.mp4" data-thumbnail-src="#{thumbnail_src}"></div><p></p>
    HTML
  end

  def crawl
    get topic.relative_url,
        headers: {
          "User-Agent" => "Googlebot/2.1 (+http://www.google.com/bot.html)",
        }
    expect(response.status).to eq(200)
    response.body
  end

  it "links the first video's thumbnail as the image" do
    post.update_columns(cooked: video(thumbnail) + video("#{thumbnail}?2"))

    body = crawl
    expect(body).to include(image_link)
    expect(body.scan('itemprop="image"').size).to eq(1)
  end

  it "adds nothing when the post already has an image" do
    upload = Fabricate(:image_upload)
    post.update_columns(cooked: video(thumbnail), image_upload_id: upload.id)

    expect(crawl).not_to include(image_link)
  end

  it "adds nothing for a post without videos" do
    expect(crawl).not_to include('itemprop="image"')
  end

  it "skips a thumbnail that is not a web address" do
    post.update_columns(cooked: video("javascript:alert(1)"))

    expect(crawl).not_to include('itemprop="image"')
  end

  it "does nothing when the setting is off" do
    SiteSetting.jtech_video_post_schema_image = false
    post.update_columns(cooked: video(thumbnail))

    expect(crawl).not_to include(image_link)
  end
end
