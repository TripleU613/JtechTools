# frozen_string_literal: true

# Trust level flair: everyone who hasn't picked a flair shows their trust
# level group's. Core only shows a flair someone chose (Preferences → Account
# → Flair), so most members showed none, though the trust level groups have
# flair icons.
module ::DiscourseTrustLevelFlair
  # The flair group this last gave the user. A flair that's still this one is
  # the plugin's to move when the trust level changes; any other (or none,
  # once this gave one) is the user's own choice and is left alone.
  FIELD = "jtech_trust_level_flair"

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_trust_level_flair
  end

  # Gives each user (all, or user_ids) the flair of their highest trust level
  # group that has one and that they're in. Two queries whatever the number
  # of users. Returns the ids it changed.
  def self.sync!(user_ids: nil)
    return [] unless enabled?
    return [] if user_ids && user_ids.empty?

    rows = DB.query(<<~SQL, field: FIELD, tl0: Group::AUTO_GROUPS[:trust_level_0], ids: user_ids)
      WITH wanted AS (
        SELECT u.id AS user_id, g.id AS group_id
        FROM users u
        LEFT JOIN user_custom_fields f ON f.user_id = u.id AND f.name = :field
        JOIN LATERAL (
          SELECT groups.id
          FROM groups
          JOIN group_users ON group_users.group_id = groups.id AND group_users.user_id = u.id
          WHERE groups.id BETWEEN :tl0 AND :tl0 + LEAST(u.trust_level, 4)
            AND (COALESCE(groups.flair_icon, '') <> '' OR groups.flair_upload_id IS NOT NULL)
          ORDER BY groups.id DESC
          LIMIT 1
        ) g ON TRUE
        WHERE u.id > 0
          AND NOT u.staged
          #{user_ids ? "AND u.id IN (:ids)" : ""}
          AND (
            (u.flair_group_id IS NULL AND f.value IS NULL)
            OR (u.flair_group_id::text = f.value AND f.value <> g.id::text)
          )
      )
      UPDATE users
      SET flair_group_id = wanted.group_id
      FROM wanted
      WHERE users.id = wanted.user_id
      RETURNING users.id, users.flair_group_id
    SQL
    return [] if rows.empty?

    ids = rows.map(&:id)
    now = Time.zone.now
    UserCustomField.where(user_id: ids, name: FIELD).delete_all
    UserCustomField.insert_all(
      rows.map do |row|
        {
          user_id: row.id,
          name: FIELD,
          value: row.flair_group_id.to_s,
          created_at: now,
          updated_at: now,
        }
      end,
    )
    ids
  end
end
