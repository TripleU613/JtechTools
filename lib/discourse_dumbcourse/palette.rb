# frozen_string_literal: true

module DiscourseDumbcourse
  # Dumbcourse's colour tokens (dumbcourse/styles/00-tokens.scss) from the
  # forum palettes the reader uses, so it has the forum's colours: :root takes
  # the dark palette, html.light the light one. The page carries them in a
  # <style> after its stylesheet. Browsers without custom properties keep the
  # stylesheet's own values, which are these for JTech Dark and JTech Light.
  module Palette
    HEX = /\A\h{3}(\h{3})?\z/

    def self.style(user:, cookies:)
      theme = Theme.find_by(id: SiteSetting.default_theme_id)
      return "" if theme.nil?

      light = pick(cookies[:color_scheme_id] || user&.user_option&.color_scheme_id, theme, :light)
      dark =
        pick(cookies[:dark_scheme_id] || user&.user_option&.dark_scheme_id, theme, :dark) || light
      return "" if light.nil?

      ":root{#{declarations(tokens(dark, dark: true))}}" \
        "html.light{#{declarations(tokens(light, dark: false))}}"
    end

    # As core's ApplicationHelper#scheme_id / #dark_scheme_id: the reader's
    # choice (this device's cookie, else their account) when they may use it
    # with the theme, else the theme's own.
    def self.pick(chosen, theme, mode)
      default_id = mode == :dark ? theme.dark_color_scheme_id : theme.color_scheme_id
      scope = ColorScheme.all
      scope = scope.where(theme_id: theme.id) if theme.theme_modifier_set&.only_theme_color_schemes
      scope = scope.where(user_selectable: true).or(scope.where(id: default_id))
      (chosen.to_i > 0 && scope.find_by(id: chosen.to_i)) ||
        (default_id.to_i > 0 && ColorScheme.find_by(id: default_id)) || nil
    end

    # The palette's own ramp where it has one (the JTech palettes all do),
    # otherwise its ink mixed into its paper.
    def self.tokens(scheme, dark:)
      c = scheme.resolved_colors
      paper = c["secondary"]
      ink = c["primary"]
      accent = c["tertiary"]
      ramp = ->(name, weight) { c[name] || mix(paper, ink, weight) }
      tint = ->(hex, weight) { mix(paper, hex, weight) }
      {
        "bg" => dark ? paper : ramp.("primary-very-low", 0.02),
        "surface" => dark ? ramp.("primary-very-low", 0.04) : paper,
        "surface2" => ramp.("primary-100", dark ? 0.07 : 0.05),
        "surface3" => ramp.("primary-200", dark ? 0.1 : 0.08),
        "line" => ramp.("primary-300", dark ? 0.18 : 0.12),
        "fg" => ink,
        "fg2" => ramp.("primary-high", 0.6),
        "fg3" => ramp.("primary-medium", 0.55),
        "accent" => accent,
        "accent-strong" => c["tertiary-hover"] || mix(accent, dark ? "ffffff" : "000000", 0.2),
        "accent-fg" => paper,
        "accent-soft" => c["tertiary-low"] || tint.(accent, 0.14),
        "focus" => accent,
        "focus-soft" => c["tertiary-very-low"] || tint.(accent, 0.06),
        "danger" => c["danger"],
        "danger-fg" => paper,
        "danger-soft" => tint.(c["danger"], 0.14),
        "ok" => c["success"],
        "ok-soft" => tint.(c["success"], 0.14),
        "unread" => accent,
        "code" => c["hljs-bg"] || ramp.("primary-very-low", 0.03),
      }
    end

    # Only hex values reach the page
    def self.declarations(tokens)
      tokens.filter_map { |name, hex| "--#{name}:##{hex.downcase};" if HEX.match?(hex.to_s) }.join
    end

    # weight of b into a, both hex without "#"
    def self.mix(a, b, weight)
      rgb = ->(hex) { (hex.size == 3 ? hex.chars.map { _1 * 2 } : hex.scan(/../)).map(&:hex) }
      rgb
        .(a)
        .zip(rgb.(b))
        .map { |x, y| (x + (y - x) * weight).round.clamp(0, 255).to_s(16).rjust(2, "0") }
        .join
    end
  end
end
