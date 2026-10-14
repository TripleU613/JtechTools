# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::DiscourseJtechTheme::Installer do
  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_theme_install = true
  end

  def installed
    described_class.theme
  end

  it "runs from the seeds every db:migrate runs" do
    fixtures = File.realpath(File.expand_path("../../../db/fixtures", __dir__))
    registered =
      DiscoursePluginRegistry.seed_paths.filter_map { |p| File.realpath(p) if File.exist?(p) }

    expect(registered).to include(fixtures)
  end

  describe ".sync_now" do
    it "installs the bundled theme without making it the default or user-selectable" do
      result = nil
      expect { result = described_class.sync_now }.to change { Theme.count }.by(1)
      expect(result).to eq(:installed)

      theme = installed
      expect(theme.name).to eq("JTech")
      expect(theme.component).to eq(false)
      expect(theme.id).to be > 0
      expect(theme.user_selectable).to eq(false)
      expect(SiteSetting.default_theme_id).not_to eq(theme.id)
      expect(theme.color_schemes.pluck(:name)).to contain_exactly(
        "JTech Light",
        "JTech Dark",
        *described_class::OFFERED_PALETTES,
      )
      expect(described_class.state["digest"]).to eq(described_class.digest)
    end

    it "does nothing when the bundled theme hasn't changed" do
      described_class.sync_now
      theme = installed

      result = nil
      expect { result = described_class.sync_now }.not_to change { Theme.count }
      expect(result).to eq(:unchanged)
      expect(installed.updated_at).to eq_time(theme.updated_at)
    end

    it "updates the same theme when the bundled theme changes" do
      described_class.sync_now
      id = installed.id
      described_class.save_state(described_class.state.merge("digest" => "older"))

      result = nil
      expect { result = described_class.sync_now }.not_to change { Theme.count }
      expect(result).to eq(:updated)
      expect(installed.id).to eq(id)
      expect(described_class.state["digest"]).to eq(described_class.digest)
    end

    it "keeps admin choices when it updates" do
      described_class.sync_now
      theme = installed
      theme.update!(user_selectable: true)
      SiteSetting.default_theme_id = theme.id
      described_class.save_state(described_class.state.merge("digest" => "older"))

      described_class.sync_now

      expect(installed.user_selectable).to eq(true)
      expect(SiteSetting.default_theme_id).to eq(theme.id)
    end

    it "lets people choose the colour pairs, but only the theme's defaults are the defaults" do
      described_class.sync_now
      theme = installed

      expect(theme.color_schemes.find_by(name: "JTech Dim")).to be_nil
      expect(theme.color_scheme.name).to eq("JTech Light")
      expect(theme.dark_color_scheme.name).to eq("JTech Dark")
      expect(theme.color_schemes.where(user_selectable: true).pluck(:name)).to match_array(
        described_class::OFFERED_PALETTES,
      )
      expect(theme.color_schemes.find_by(name: "Nord Light").is_dark?).to eq(false)
      expect(theme.color_schemes.find_by(name: "Nord Dark").is_dark?).to eq(true)
    end

    it "offers palettes a later version adds" do
      described_class.sync_now
      # as installed by a version that only had Nord to offer
      installed
        .color_schemes
        .where.not(name: ["Nord Light", "Nord Dark"])
        .update_all(user_selectable: false)
      described_class.save_state(
        described_class.state.merge(
          "digest" => "older",
          "offered_palettes" => ["Nord Light", "Nord Dark"],
        ),
      )

      described_class.sync_now

      expect(installed.color_schemes.where(user_selectable: true).pluck(:name)).to match_array(
        described_class::OFFERED_PALETTES,
      )
    end

    it "doesn't offer a palette again after an admin stops offering it" do
      described_class.sync_now
      installed.color_schemes.find_by(name: "Nord Dark").update!(user_selectable: false)
      described_class.save_state(described_class.state.merge("digest" => "older"))

      described_class.sync_now

      expect(installed.color_schemes.find_by(name: "Nord Dark").user_selectable).to eq(false)
    end

    # JTech Dim's greys became Discourse Dark's: whoever had picked Dim moves
    # there before the import deletes it
    it "moves the people on a retired palette to the one that replaced it" do
      described_class.sync_now
      dim = installed.color_schemes.create!(name: "JTech Dim", user_selectable: true)
      user = Fabricate(:user)
      user.user_option.update!(dark_scheme_id: dim.id, color_scheme_id: dim.id)
      described_class.save_state(described_class.state.merge("digest" => "older"))

      described_class.sync_now

      successor = installed.color_schemes.find_by(name: "Discourse Dark")
      expect(ColorScheme.exists?(dim.id)).to eq(false)
      expect(user.user_option.reload.dark_scheme_id).to eq(successor.id)
      expect(user.user_option.color_scheme_id).to eq(successor.id)
    end

    it "leaves a theme an admin deleted deleted" do
      described_class.sync_now
      installed.destroy!

      result = nil
      expect { result = described_class.sync_now }.not_to change { Theme.count }
      expect(result).to eq(:removed)
      expect(described_class.state["removed_at"]).to be_present
      expect(described_class.sync_now).to eq(:removed)
    end
  end

  describe "a JTech theme installed by hand from Git before the plugin shipped it" do
    fab!(:hand_installed) do
      repo =
        RemoteTheme.create!(
          remote_url: "https://github.com/example/jtech-theme.git",
          about_url: "https://jtechforums.org",
        )
      theme = Fabricate(:theme, name: "JTech")
      theme.update!(remote_theme: repo)
      theme
    end

    it "is updated in place instead of getting a second JTech next to it" do
      hand_installed.set_default!

      result = nil
      expect { result = described_class.sync_now }.not_to change { Theme.count }
      expect(result).to eq(:adopted)
      expect(installed.id).to eq(hand_installed.id)
      expect(SiteSetting.default_theme_id).to eq(hand_installed.id)
      expect(installed.color_schemes.pluck(:name)).to contain_exactly(
        "JTech Light",
        "JTech Dark",
        *described_class::OFFERED_PALETTES,
      )
    end

    it "stops following the Git repo, so core's theme updates can't pull it back" do
      described_class.sync_now

      expect(installed.id).to eq(hand_installed.id)
      expect(installed.remote_theme).to be_nil
    end

    it "leaves an unrelated theme that happens to be called JTech alone" do
      hand_installed.remote_theme.update!(about_url: "https://example.com")

      expect { described_class.sync_now }.to change { Theme.count }.by(1)
      expect(installed.id).not_to eq(hand_installed.id)
      expect(hand_installed.reload.remote_theme).to be_present
    end
  end

  describe "a JTech theme uploaded by hand (zip or theme CLI) before the plugin shipped it" do
    fab!(:hand_installed) { RemoteTheme.import_theme_from_directory(described_class.directory) }

    it "is updated in place, though core links no RemoteTheme to an upload" do
      expect(hand_installed.reload.remote_theme).to be_nil
      hand_installed.set_default!

      result = nil
      expect { result = described_class.sync_now }.not_to change { Theme.count }
      expect(result).to eq(:adopted)
      expect(installed.id).to eq(hand_installed.id)
      expect(SiteSetting.default_theme_id).to eq(hand_installed.id)
    end
  end

  describe ".restore!" do
    it "brings back a deleted theme and otherwise just syncs" do
      described_class.sync_now
      installed.destroy!
      described_class.sync_now

      expect(described_class.restore!).to eq(:installed)
      expect(installed).to be_present
      expect(described_class.restore!).to eq(:unchanged)
    end
  end

  describe "turning jtech_theme_install on" do
    it "queues a sync so the theme arrives without a rebuild" do
      SiteSetting.jtech_theme_install = false
      expect_enqueued_with(job: :jtech_theme_sync) { SiteSetting.jtech_theme_install = true }
    end

    it "installs the theme from the job" do
      Jobs::JtechThemeSync.new.execute({})
      expect(installed).to be_present
    end
  end

  describe ".reinstall!" do
    it "brings back a theme an admin deleted" do
      described_class.sync_now
      installed.destroy!
      described_class.sync_now

      expect { described_class.reinstall! }.to change { Theme.count }.by(1)
      expect(installed).to be_present
      expect(described_class.state["removed_at"]).to be_nil
    end
  end

  describe ".sync!" do
    it "stays out of test databases unless asked" do
      expect(described_class.sync!).to eq(:skipped_test)
      expect(installed).to be_nil
    end

    context "when asked to run" do
      around do |example|
        ENV["JTECH_THEME_SEED"] = "1"
        example.run
      ensure
        ENV.delete("JTECH_THEME_SEED")
      end

      it "does nothing when the module is switched off" do
        SiteSetting.jtech_theme_install = false
        expect(described_class.sync!).to eq(:disabled)
        expect(installed).to be_nil
      end

      it "does nothing when the bundle is switched off" do
        SiteSetting.jtech_enabled = false
        expect(described_class.sync!).to eq(:disabled)
        expect(installed).to be_nil
      end

      it "never raises, so a failed import can't stop a migration" do
        allow(RemoteTheme).to receive(:import_theme_from_directory).and_raise(
          StandardError,
          "broken theme",
        )
        expect(described_class.sync!).to eq(:failed)
      end
    end
  end
end
