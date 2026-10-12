# frozen_string_literal: true

module ::DiscourseModCategories
  # Endpoints for the first-post checklist. Two flavours are managed here:
  #
  #   * the forum-wide checklist — one list every not-yet-trusted user must
  #     tick, kept in the plugin store as
  #       { "version" => Integer, "items" => [{ "label" =>, "url" => }] }
  #   * targeted checklists — separate lists aimed at specific users, kept
  #     as a JSON array. A targeted checklist applies to its listed users
  #     regardless of trust level or staff status.
  #
  # Any user records that they have acknowledged a checklist; staff read and
  # edit the lists and the acceptance audit log.
  class ChecklistController < BaseController
    requires_login

    before_action :ensure_module_enabled

    NS = DiscourseModCategories::CHECKLIST_STORE_NAMESPACE
    KEY = DiscourseModCategories::CHECKLIST_STORE_KEY
    LOG_KEY = DiscourseModCategories::CHECKLIST_LOG_KEY
    TARGETED_KEY = DiscourseModCategories::TARGETED_CHECKLISTS_KEY
    VERSION_FIELD = DiscourseModCategories::USER_CHECKLIST_VERSION_FIELD
    TARGETED_FIELD = DiscourseModCategories::USER_TARGETED_CHECKLIST_FIELD
    TOPIC_FIELD = DiscourseModCategories::TOPIC_PROMPT_CHECKLIST_FIELD
    USER_TOPIC_FIELD = DiscourseModCategories::USER_TOPIC_CHECKLIST_FIELD
    # Most recent acceptances kept in the audit log.
    LOG_LIMIT = 500

    # Returns the current forum-wide checklist, the targeted checklists, and
    # the acceptance audit log for the moderator config page.
    def show
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_first_post_checklist_enabled)
      render json:
               checklist_json(DiscourseModCategories.checklist_config).merge(
                 log: acceptance_log,
                 targeted: targeted_json,
               )
    end

    # Replaces the forum-wide checklist and bumps the version so users who
    # already accepted an older version are prompted again.
    def update
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_first_post_checklist_enabled)

      items = parse_items(params[:items])
      existing = DiscourseModCategories.checklist_config || {}
      version = existing["version"].to_i + 1

      config = {
        "version" => version,
        "items" => items,
        "max_tl" => normalize_max_tl(params[:max_tl]),
        "button_label" => params[:button_label].to_s.strip,
        "updated_at" => Time.zone.now.iso8601,
      }
      PluginStore.set(NS, KEY, config)

      render json: checklist_json(config)
    end

    # Returns the single checklist the CURRENT user still owes before they
    # can post — the same `{ kind, id, version, items, button_label,
    # updated_at }` shape as the `mod_first_post_checklist` serializer, or
    # `null`. The frontend polls this when the composer opens so a checklist
    # version bumped mid-session is gated without a hard page refresh.
    def owed
      # A topic the user can't see has no checklist as far as they know.
      topic = Topic.find_by(id: params[:topic_id]) if params[:topic_id].present?
      topic_id = topic&.id if topic && guardian.can_see_topic?(topic)
      render json: {
               checklist:
                 DiscourseModCategories.owed_checklist_for(current_user, topic_id: topic_id),
             }
    end

    # Records that the current user has acknowledged a checklist. `kind`
    # selects which store the acceptance is recorded against. The accepted
    # version is clamped to the version actually published so a stale client
    # cannot mark a user ahead of the real checklist.
    def accept
      kind = params[:kind].to_s
      submitted = params[:version].to_i
      RateLimiter.new(current_user, "mod-checklist-accept", 20, 1.minute).performed!

      # Match the per-kind feature gates the other endpoints use — with a
      # feature off, its acceptance store must not be writable either.
      case kind
      when "targeted"
        ensure_feature!(:mod_targeted_checklists_enabled)
      when "topic"
        ensure_feature!(:mod_topic_prompt_checklist_enabled)
      else
        ensure_feature!(:mod_first_post_checklist_enabled)
      end

      if kind == "targeted"
        checklist =
          DiscourseModCategories.targeted_checklists.find { |c| c["id"] == params[:id].to_s }
        # Only the users a targeted checklist names can accept it.
        unless checklist && Array(checklist["user_ids"]).map(&:to_i).include?(current_user.id)
          raise Discourse::NotFound
        end

        accepted_version = [submitted, checklist["version"].to_i].min
        map = current_user.custom_fields[TARGETED_FIELD]
        map = {} unless map.is_a?(Hash)
        if map[checklist["id"]] != accepted_version
          map[checklist["id"]] = accepted_version
          current_user.custom_fields[TARGETED_FIELD] = map
          current_user.save_custom_fields(true)
          append_log_entry(accepted_version, kind: "targeted", id: checklist["id"])
        end
      elsif kind == "topic"
        topic = Topic.find_by(id: params[:id])
        raise Discourse::NotFound if topic.nil? || !guardian.can_see_topic?(topic)
        checklist = DiscourseModCategories.topic_prompt_checklist(topic.id)
        raise Discourse::NotFound unless checklist

        accepted_version = [submitted, checklist["version"].to_i].min
        map = current_user.custom_fields[USER_TOPIC_FIELD]
        map = {} unless map.is_a?(Hash)
        if map[topic.id.to_s] != accepted_version
          map[topic.id.to_s] = accepted_version
          current_user.custom_fields[USER_TOPIC_FIELD] = map
          current_user.save_custom_fields(true)
          append_log_entry(accepted_version, kind: "topic", id: topic.id.to_s)
        end
      else
        current = DiscourseModCategories.checklist_config&.dig("version").to_i
        accepted_version = [submitted, current].min
        if current_user.custom_fields[VERSION_FIELD].to_i != accepted_version
          current_user.custom_fields[VERSION_FIELD] = accepted_version
          current_user.save_custom_fields(true)
          append_log_entry(accepted_version, kind: "global")
        end
      end

      render json: success_json
    end

    # Resets a user so they are re-prompted for the forum-wide checklist on
    # their next post, by zeroing their recorded accepted version.
    def require_reaccept
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_first_post_checklist_enabled)

      user = find_target_user
      raise Discourse::NotFound unless user

      user.custom_fields[VERSION_FIELD] = 0
      user.save_custom_fields(true)

      render json: { success: "OK", log: acceptance_log }
    end

    # Creates a targeted checklist with a stable id, starting at version 1.
    def create_targeted
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_targeted_checklists_enabled)

      checklist = {
        "id" => SecureRandom.hex(8),
        "name" => params[:name].to_s.strip,
        "user_ids" => validate_user_ids(params[:user_ids]),
        "items" => parse_items(params[:items]),
        "version" => 1,
        "button_label" => params[:button_label].to_s.strip,
        "updated_at" => Time.zone.now.iso8601,
      }
      checklists = DiscourseModCategories.targeted_checklists + [checklist]
      PluginStore.set(NS, TARGETED_KEY, checklists)

      render json: { targeted: targeted_json }
    end

    # Replaces a targeted checklist's content and bumps its version so its
    # users are re-prompted.
    def update_targeted
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_targeted_checklists_enabled)

      checklists = DiscourseModCategories.targeted_checklists
      checklist = checklists.find { |c| c["id"] == params[:id].to_s }
      raise Discourse::NotFound unless checklist

      checklist["name"] = params[:name].to_s.strip
      checklist["user_ids"] = validate_user_ids(params[:user_ids])
      checklist["items"] = parse_items(params[:items])
      checklist["button_label"] = params[:button_label].to_s.strip
      checklist["version"] = checklist["version"].to_i + 1
      checklist["updated_at"] = Time.zone.now.iso8601
      PluginStore.set(NS, TARGETED_KEY, checklists)

      render json: { targeted: targeted_json }
    end

    # Removes a targeted checklist.
    def delete_targeted
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_targeted_checklists_enabled)

      checklists = DiscourseModCategories.targeted_checklists
      remaining = checklists.reject { |c| c["id"] == params[:id].to_s }
      raise Discourse::NotFound if remaining.size == checklists.size

      PluginStore.set(NS, TARGETED_KEY, remaining)

      render json: { targeted: targeted_json }
    end

    # --- Per-topic prompt checklist ----------------------------------

    # Returns the per-topic prompt checklist for a topic, in the same
    # shape the editor expects. Empty/absent stores return zeroed fields
    # so the editor can render an empty form.
    def show_topic
      topic = find_topic!
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_prompt_checklist_enabled)

      render json: topic_checklist_json(topic)
    end

    # Replaces the topic's prompt checklist and bumps the version so any
    # user who already accepted is re-prompted. Accepts the new mode,
    # statement, frequency, and max_tl fields alongside the historical
    # items + button_label shape. Saving migrates a legacy reply-prompt:
    # the two legacy `mod_topic_reply_prompt*` custom fields are cleared
    # so the new config wins outright.
    def update_topic
      topic = find_topic!
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_prompt_checklist_enabled)

      mode = params[:mode].to_s
      mode = "checklist" if %w[statement checklist].exclude?(mode)
      frequency = params[:frequency].to_s
      frequency = "once" if %w[once every_reply].exclude?(frequency)
      statement = params[:statement].to_s
      max_tl = normalize_topic_max_tl(params[:max_tl])

      items = parse_items(params[:items])
      existing = topic_checklist_raw(topic) || {}
      version = existing["version"].to_i + 1

      config = {
        "version" => version,
        "mode" => mode,
        "statement" => statement,
        "items" => items,
        "frequency" => frequency,
        "max_tl" => max_tl,
        "button_label" => params[:button_label].to_s.strip,
        "updated_at" => Time.zone.now.iso8601,
      }
      topic.custom_fields[TOPIC_FIELD] = config
      # Migrate away from the legacy per-topic reply prompt fields: the
      # new config supersedes them, and the composer gate already prefers
      # the per-topic checklist. Clearing means a stale legacy prompt
      # never appears after the staff explicitly saves the new config.
      topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_FIELD] = nil
      topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_TL_FIELD] = nil
      topic.save_custom_fields(true)

      render json: topic_checklist_json(topic)
    end

    # Clears the per-topic prompt checklist.
    def delete_topic
      topic = find_topic!
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_prompt_checklist_enabled)

      topic.custom_fields[TOPIC_FIELD] = nil
      topic.save_custom_fields(true)

      render json: topic_checklist_json(topic)
    end

    private

    # 404s when a per-feature toggle is off, so each checklist flavour can be
    # revoked individually from the plugin settings.
    # Resolves the user named by a `username` or `user_id` param.
    def find_target_user
      if params[:user_id].present?
        User.find_by(id: params[:user_id])
      elsif params[:username].present?
        User.find_by_username(params[:username])
      end
    end

    # Resolves the submitted target list to ids of real User records. The
    # frontend's user picker sends usernames, but a numeric id is accepted
    # too. A browser form-encodes an array as an index-keyed hash, so
    # accept that shape as well.
    def validate_user_ids(raw)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raw = raw.values if raw.is_a?(Hash)
      tokens = Array(raw).map(&:to_s).map(&:strip).reject(&:empty?).uniq

      numeric, names = tokens.partition { |t| t.match?(/\A\d+\z/) }
      ids = numeric.map(&:to_i)
      ids += User.where(username_lower: names.map(&:downcase)).pluck(:id)
      User.where(id: ids.uniq).pluck(:id)
    end

    # Appends one acceptance to the audit log, keeping the most recent
    # LOG_LIMIT entries.
    # The log is one plugin-store row, so concurrent accepts are serialized
    # to keep one from overwriting another's entry.
    def append_log_entry(version, kind: "global", id: nil)
      DistributedMutex.synchronize("mod_checklist_acceptance_log") do
        raw = PluginStore.get(NS, LOG_KEY)
        entries = raw.is_a?(Array) ? raw : []
        entries << {
          "user_id" => current_user.id,
          "version" => version,
          "at" => Time.zone.now.iso8601,
          "kind" => kind,
          "checklist_id" => id,
        }
        PluginStore.set(NS, LOG_KEY, entries.last(LOG_LIMIT))
      end
    end

    # The acceptance audit log, newest first, with usernames resolved.
    def acceptance_log
      raw = PluginStore.get(NS, LOG_KEY)
      entries = raw.is_a?(Array) ? raw : []
      users = User.where(id: entries.map { |e| e["user_id"] }.uniq).index_by(&:id)
      names =
        DiscourseModCategories
          .targeted_checklists
          .each_with_object({}) { |c, h| h[c["id"]] = c["name"] }

      entries.reverse.map do |entry|
        user = users[entry["user_id"]]
        {
          username: user&.username,
          name: user&.name,
          avatar_template: user&.avatar_template,
          version: entry["version"].to_i,
          accepted_at: entry["at"],
          kind: entry["kind"].presence || "global",
          checklist_id: entry["checklist_id"],
          checklist_name: names[entry["checklist_id"]],
        }
      end
    end

    def checklist_json(config)
      config ||= {}
      {
        version: config["version"].to_i,
        items: config["items"].is_a?(Array) ? config["items"] : [],
        max_tl: config.key?("max_tl") ? config["max_tl"].to_i : 2,
        button_label: config["button_label"].to_s,
        updated_at: config["updated_at"],
      }
    end

    # The targeted checklists, with their target users resolved to
    # username/avatar so the editor can render the picker.
    def targeted_json
      checklists = DiscourseModCategories.targeted_checklists
      all_ids = checklists.flat_map { |c| Array(c["user_ids"]).map(&:to_i) }.uniq
      users = User.where(id: all_ids).index_by(&:id)

      checklists.map do |checklist|
        ids = Array(checklist["user_ids"]).map(&:to_i)
        {
          id: checklist["id"],
          name: checklist["name"].to_s,
          version: checklist["version"].to_i,
          button_label: checklist["button_label"].to_s,
          updated_at: checklist["updated_at"],
          items: checklist["items"].is_a?(Array) ? checklist["items"] : [],
          user_ids: ids,
          users:
            ids.filter_map do |id|
              user = users[id]
              next nil unless user
              {
                id: user.id,
                username: user.username,
                name: user.name,
                avatar_template: user.avatar_template,
              }
            end,
        }
      end
    end

    # Highest trust level still required to accept the checklist: 0-2,
    # defaulting to 2 (TL0, TL1, and TL2 all must accept).
    def normalize_max_tl(value)
      return 2 if value.nil? || value.to_s.strip.empty?
      [[value.to_i, 0].max, 2].min
    end

    # Normalises submitted rows. A browser form-encodes an array of
    # objects as a hash keyed by index ({ "0" => {...}, "1" => {...} }),
    # so coerce that back to an array. Each row needs a non-blank label;
    # the url is optional. Blank-label rows are dropped.
    # Reads the per-topic checklist hash off the topic, coercing a legacy
    # string-stored value back to a hash.
    def topic_checklist_raw(topic)
      raw = topic.custom_fields[TOPIC_FIELD]
      raw =
        begin
          JSON.parse(raw)
        rescue StandardError
          nil
        end if raw.is_a?(String)
      raw.is_a?(Hash) ? raw : nil
    end

    # The editor-facing payload for the per-topic checklist. When no new
    # config exists for the topic but a legacy `mod_topic_reply_prompt`
    # has been set on the topic, pre-fill the editor in Statement mode
    # with the legacy text + the legacy `mod_topic_reply_prompt_max_tl`
    # cap so the moderator can save once to migrate.
    def topic_checklist_json(topic)
      raw = topic_checklist_raw(topic)

      if raw.nil?
        legacy_text = topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_FIELD].to_s
        if legacy_text.strip.length > 0
          legacy_max_tl = topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_TL_FIELD]
          legacy_max_tl =
            (
              if legacy_max_tl.nil? || legacy_max_tl.to_s.strip.empty?
                4
              else
                [[legacy_max_tl.to_i, 0].max, 4].min
              end
            )
          return(
            {
              topic_id: topic.id,
              version: 0,
              mode: "statement",
              statement: legacy_text,
              items: [],
              frequency: "once",
              max_tl: legacy_max_tl,
              button_label: "",
              updated_at: nil,
              from_legacy: true,
            }
          )
        end
        raw = {}
      end

      mode = raw["mode"].to_s
      mode = "checklist" if %w[statement checklist].exclude?(mode)
      frequency = raw["frequency"].to_s
      frequency = "once" if %w[once every_reply].exclude?(frequency)
      max_tl = raw.key?("max_tl") ? normalize_topic_max_tl(raw["max_tl"]) : 4

      {
        topic_id: topic.id,
        version: raw["version"].to_i,
        mode: mode,
        statement: raw["statement"].to_s,
        items: raw["items"].is_a?(Array) ? raw["items"] : [],
        frequency: frequency,
        max_tl: max_tl,
        button_label: raw["button_label"].to_s,
        updated_at: raw["updated_at"],
        from_legacy: false,
      }
    end

    # Per-topic trust-level cap: 0-4, defaulting to 4 (everyone). Mirrors
    # the global checklist's `max_tl` but allows TL3/TL4 too so a staff
    # member can wholly opt out of trust-level filtering.
    def normalize_topic_max_tl(value)
      return 4 if value.nil? || value.to_s.strip.empty?
      [[value.to_i, 0].max, 4].min
    end

    def parse_items(raw)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raw = raw.values if raw.is_a?(Hash)
      rows = raw.is_a?(Array) ? raw : []
      rows
        .map do |row|
          row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
          next nil unless row.is_a?(Hash)
          label = row["label"].to_s.strip
          url = row["url"].to_s.strip
          next nil if label.empty?
          { "label" => label, "url" => url }
        end
        .compact
    end
  end
end
