# frozen_string_literal: true

module DiscourseDiscordMirror
  # Keeps the Discord server's channels in step with the forum's public
  # categories: a Discord channel category per top-level category, and a
  # forum channel (with its own webhook) per category and subcategory.
  module Structure
    module_function

    GUILD_CATEGORY = 4
    GUILD_FORUM = 15
    # Read-only for members: no posts, replies or threads of their own.
    READ_ONLY_DENY = (1 << 11) | (1 << 35) | (1 << 36) | (1 << 38)
    TOPIC_LIMIT = 1024
    # Discord's own channels (#rules and the like) stay above ours.
    POSITION_OFFSET = 10

    def guild_id
      SiteSetting.discord_mirror_guild_id.to_s.strip
    end

    def api
      Api.new
    end

    def categories
      Category
        .includes(:parent_category)
        .order(:position, :id)
        .select { |c| Visibility.category?(c) }
    end

    # The mirror row for `category`, creating the Discord side on first use.
    # nil when the category isn't mirrored.
    def channel_for(category)
      return nil unless Visibility.category?(category)
      MirrorChannel.find_by(category_id: category.id) || create_channel(category)
    end

    def create_channel(category)
      DistributedMutex.synchronize("discord_mirror_category_#{category.id}") do
        existing = MirrorChannel.find_by(category_id: category.id)
        return existing if existing

        group_id =
          if category.parent_category_id
            channel_for(category.parent_category)&.discord_group_id
          else
            create_group(category)
          end
        return nil if group_id.blank?

        forum =
          api.bot(
            :post,
            "/guilds/#{guild_id}/channels",
            {
              name: category.name.truncate(100),
              type: GUILD_FORUM,
              parent_id: group_id,
              topic: topic_text(category),
              permission_overwrites: [{ id: guild_id, type: 0, deny: READ_ONLY_DENY.to_s }],
            },
          )
        webhook = api.bot(:post, "/channels/#{forum["id"]}/webhooks", { name: "JTech Forums" })

        MirrorChannel.create!(
          category_id: category.id,
          discord_group_id: group_id,
          discord_channel_id: forum["id"],
          webhook_id: webhook["id"],
          webhook_token: webhook["token"],
        )
      end
    end

    def create_group(category)
      group =
        api.bot(
          :post,
          "/guilds/#{guild_id}/channels",
          {
            name: category.name.truncate(100),
            type: GUILD_CATEGORY,
            permission_overwrites: [{ id: guild_id, type: 0, deny: READ_ONLY_DENY.to_s }],
          },
        )
      group["id"]
    end

    def topic_text(category)
      [
        category.description_text.to_s.squish.presence,
        category.url.then { |u| "#{Discourse.base_url}#{u}" },
      ].compact.join("\n").truncate(TOPIC_LIMIT)
    end

    # Creates what's missing, renames what changed, removes what's no longer
    # public, and orders everything like the forum.
    def reconcile
      wanted = categories
      wanted_ids = wanted.map(&:id)

      MirrorChannel.where.not(category_id: wanted_ids).order(:id).each { |row| remove(row) }

      rows = {}
      wanted.each do |category|
        row = channel_for(category)
        next if row.nil?
        rows[category.id] = row
        update_channel(row, category)
      end

      order(wanted, rows)
    end

    def update_channel(row, category)
      api.bot(
        :patch,
        "/channels/#{row.discord_channel_id}",
        { name: category.name.truncate(100), topic: topic_text(category) },
      )
      if category.parent_category_id.nil? && row.discord_group_id.present?
        api.bot(:patch, "/channels/#{row.discord_group_id}", { name: category.name.truncate(100) })
      end
    rescue Api::NotFound
      # Someone deleted it on Discord; forget it so the next run rebuilds it.
      forget(row)
    end

    def order(wanted, rows)
      positions = []
      tops = wanted.select { |c| c.parent_category_id.nil? }
      tops.each_with_index do |top, index|
        row = rows[top.id]
        next if row.nil?
        positions << { id: row.discord_group_id, position: POSITION_OFFSET + index }
        children = [top] + wanted.select { |c| c.parent_category_id == top.id }
        children.each_with_index do |child, child_index|
          child_row = rows[child.id]
          positions << { id: child_row.discord_channel_id, position: child_index } if child_row
        end
      end
      if positions.any?
        api.bot(:patch, "/guilds/#{guild_id}/channels", positions.uniq { |p| p[:id] })
      end
    end

    def remove(row)
      begin
        api.bot(:delete, "/channels/#{row.discord_channel_id}")
      rescue Api::NotFound
        nil
      end
      group_id = row.discord_group_id
      forget(row)
      if group_id.present? && !MirrorChannel.where(discord_group_id: group_id).exists?
        begin
          api.bot(:delete, "/channels/#{group_id}")
        rescue Api::NotFound
          nil
        end
      end
    end

    def forget(row)
      topic_ids = MirrorThread.where(category_id: row.category_id).pluck(:topic_id)
      MirrorMessage.where(topic_id: topic_ids).delete_all
      MirrorThread.where(topic_id: topic_ids).delete_all
      row.destroy!
    end
  end
end
