# frozen_string_literal: true

module DiscourseDiscordMirror
  class MirrorChannel < ActiveRecord::Base
    self.table_name = "discord_mirror_channels"
  end

  class MirrorThread < ActiveRecord::Base
    self.table_name = "discord_mirror_threads"
  end

  class MirrorMessage < ActiveRecord::Base
    self.table_name = "discord_mirror_messages"
  end
end
