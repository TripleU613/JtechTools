# frozen_string_literal: true

# Moving a whisper into a new topic (or ahead of a topic's first post in
# chronological order) made it the topic's first post, and the topic took
# its excerpt and picture from it, and a category whose topic it was its
# description: the whisper's text and image in topic and category lists, for
# everyone. Such moves are refused now, and a whisper never writes any of
# them again; this clears what the earlier ones wrote.
class ClearWhisperFirstPostCopies < ActiveRecord::Migration[7.2]
  WHISPER_FIRST_POST = <<~SQL
    SELECT 1
      FROM posts p
      JOIN post_custom_fields f ON f.post_id = p.id
     WHERE p.topic_id = %{topic_id}
       AND p.post_number = 1
       AND f.name = 'mod_whisper_target_user_ids'
  SQL

  def up
    execute <<~SQL
      UPDATE topics t
         SET excerpt = NULL,
             image_upload_id = NULL
       WHERE EXISTS (#{format(WHISPER_FIRST_POST, topic_id: "t.id")})
         AND (t.excerpt IS NOT NULL OR t.image_upload_id IS NOT NULL)
    SQL

    execute <<~SQL
      UPDATE categories c
         SET description = NULL
       WHERE EXISTS (#{format(WHISPER_FIRST_POST, topic_id: "c.topic_id")})
         AND c.description IS NOT NULL
    SQL
  end

  def down
  end
end
