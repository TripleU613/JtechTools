# frozen_string_literal: true

# A topic an earlier move left headed by a whisper was given the whisper's
# author as its owner (core takes the first post's), so topic lists showed
# who wrote a post most people can't see. Such moves are refused now; here
# the owner of each such topic becomes the author of its first public post,
# or else whoever moved the whisper there, or else the system user.
class GiveWhisperHeadedTopicsAPublicOwner < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE topics t
         SET user_id = COALESCE(
               (
                 SELECT p.user_id
                   FROM posts p
                  WHERE p.topic_id = t.id
                    AND p.deleted_at IS NULL
                    AND p.post_type = 1
                    AND p.user_id IS NOT NULL
                    AND NOT EXISTS (
                      SELECT 1 FROM post_custom_fields pf
                       WHERE pf.post_id = p.id AND pf.name = 'mod_whisper_target_user_ids'
                    )
                  ORDER BY p.post_number
                  LIMIT 1
               ),
               (
                 SELECT mp.user_id
                   FROM moved_posts mp
                  WHERE mp.new_post_id = w.id AND mp.user_id IS NOT NULL
                  ORDER BY mp.created_at DESC
                  LIMIT 1
               ),
               -1
             )
        FROM posts w
        JOIN post_custom_fields wf
          ON wf.post_id = w.id AND wf.name = 'mod_whisper_target_user_ids'
       WHERE w.topic_id = t.id
         AND w.post_number = 1
         AND t.user_id = w.user_id
    SQL
  end

  def down
  end
end
