# frozen_string_literal: true

# mod_whisper_enabled used to switch off only the tools for writing
# whispers; the rest of the whisper code ran on every forum regardless. It
# now switches all of it, so every forum starts this version with whispers
# off (its default) and turns them back on if it wants them. 20261015000001
# had written it on for existing installs.
class SwitchWhispersOff < ActiveRecord::Migration[7.2]
  def up
    execute "DELETE FROM site_settings WHERE name = 'mod_whisper_enabled'"
  end

  def down
  end
end
