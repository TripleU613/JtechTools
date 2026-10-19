# frozen_string_literal: true

# Moving a whisper into a new topic (or ahead of a topic's first post in
# chronological order) made it the topic's first post, and the topic took
# its excerpt and picture from it: the whisper's text and image in topic
# lists, for everyone. Such moves are refused now, and a whisper never
# writes either again; this clears what the earlier ones wrote.
class ClearWhisperTopicExcerpts < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE topics t
         SET excerpt = NULL,
             image_upload_id = NULL
       WHERE EXISTS (
         SELECT 1
           FROM posts p
           JOIN post_custom_fields f ON f.post_id = p.id
          WHERE p.topic_id = t.id
            AND p.post_number = 1
            AND f.name = 'mod_whisper_target_user_ids'
       )
         AND (t.excerpt IS NOT NULL OR t.image_upload_id IS NOT NULL)
    SQL
  end

  def down
  end
end
