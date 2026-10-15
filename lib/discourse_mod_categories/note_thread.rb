# frozen_string_literal: true

module DiscourseModCategories
  # The moderator note thread as JSON: the same from the topic view and from
  # every note action, so the frontend can swap one for the other without a
  # topic reload. Reply authors are loaded in one query.
  module NoteThread
    # A note an admin wrote is the admins', replies and all: to a moderator
    # it isn't there, as an admin's whisper isn't.
    def self.admins_only?(topic)
      return false if topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s.strip.empty?
      user_id = topic.custom_fields[TOPIC_PRIVATE_NOTE_USER_FIELD]
      user_id.present? && User.where(id: user_id.to_i, admin: true).exists?
    end

    def self.hidden_from?(topic, user)
      !user&.admin? && admins_only?(topic)
    end

    def self.author(topic)
      user_id = topic.custom_fields[TOPIC_PRIVATE_NOTE_USER_FIELD]
      user_json(user_id && User.find_by(id: user_id))
    end

    # Each reply with its stable id (worked out for legacy replies that
    # predate ids), its text and its author.
    def self.replies(topic)
      entries = topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD]
      entries = [] unless entries.is_a?(Array)
      authors = User.where(id: entries.filter_map { |entry| entry["user_id"] }).index_by(&:id)
      entries.map do |entry|
        {
          id: DiscourseModCategories.note_reply_id(entry),
          raw: entry["raw"].to_s,
          created_at: entry["created_at"],
          author: user_json(authors[entry["user_id"].to_i]),
        }
      end
    end

    # Who has looked at the note, as stored when they did.
    def self.viewers(entries)
      Array(entries).map do |entry|
        {
          user_id: entry["user_id"],
          username: entry["username"],
          name: entry["name"],
          avatar_template: entry["avatar_template"],
          viewed_at: entry["viewed_at"],
        }
      end
    end

    def self.user_json(user)
      return if user.nil?
      { username: user.username, name: user.name, avatar_template: user.avatar_template }
    end
  end
end
