# frozen_string_literal: true

require "rack/mime"

module DiscourseDumbcourse
  # Serves the Dumbcourse single-page app: its static files from the
  # plugin's public/ directory, and for every other path the app page with
  # the boot data (site, categories, the signed-in user, CSRF token) in a
  # non-executable JSON block, so the first screen needs no extra round
  # trips on a slow phone connection.
  class AppController < ::ActionController::Base
    requires_plugin "jtech-tools"
    include ::CurrentUser

    layout false
    # CSRF checks for the one write here. (Not for `show`: Rails' same-origin
    # JavaScript check would refuse to serve dumbcourse.js itself.)
    protect_from_forgery with: :exception, only: :hcaptcha
    before_action :ensure_enabled
    before_action :security_headers
    before_action :redirect_anonymous_to_login

    PUBLIC_ROOT = Engine.root.join("public")

    # Screens a signed-out visitor may open (the app routes them itself).
    PUBLIC_SCREENS =
      %r{\A(login|signup|register|password-reset|email-login|activate-account|preferences|help|full-site|settings)(/|\z)}

    def show
      file = static_file
      return serve_static(file) if file

      html = page_html
      response.headers["Cache-Control"] = "no-store"
      render html: html.html_safe, content_type: "text/html"
    end

    # Kept for the hCaptcha sign-up flow of discourse-captcha.
    def hcaptcha
      raise Discourse::NotFound unless setting(:discourse_captcha_enabled)
      token = params[:token].to_s
      raise Discourse::InvalidAccess.new if token.blank? || token.length > 5000

      temp_id = SecureRandom.uuid
      Discourse.redis.setex("hCaptchaToken_#{temp_id}", 2.minutes.to_i, token)
      cookies.encrypted[:h_captcha_temp_id] = {
        value: temp_id,
        httponly: true,
        secure: SiteSetting.force_https,
        expires: 2.minutes.from_now,
        same_site: :lax,
      }
      render json: { success: "OK" }
    end

    # The early theme script is inlined in <head>; the CSP allows exactly
    # that script by its hash.
    def self.early_script
      path = PUBLIC_ROOT.join("dumbcourse-early.js")
      mtime =
        begin
          path.mtime.to_i
        rescue StandardError
          0
        end
      if @early_mtime != mtime
        @early_script =
          (
            begin
              File.read(path)
            rescue StandardError
              ""
            end
          ).strip
        @early_hash = "sha256-#{Digest::SHA256.base64digest(@early_script)}"
        @early_mtime = mtime
      end
      [@early_script, @early_hash]
    end

    # A content hash for cache-busting ?v= on the app files.
    def self.asset_version
      paths = %w[dumbcourse.js dumbcourse.css].map { |f| PUBLIC_ROOT.join(f) }
      stamp =
        paths
          .map do |p|
            begin
              p.mtime.to_i
            rescue StandardError
              0
            end
          end
          .join("-")
      if @version_stamp != stamp
        @asset_version =
          Digest::SHA1.hexdigest(
            paths
              .map do |p|
                begin
                  File.binread(p)
                rescue StandardError
                  ""
                end
              end
              .join,
          )[
            0,
            12
          ]
        @version_stamp = stamp
      end
      @asset_version
    end

    private

    def request_path
      path = params[:path].to_s.split("?", 2).first.to_s
      format = params[:format].to_s
      path = "#{path}.#{format}" if format.present? && path.present? &&
        !path.end_with?(".#{format}")
      path
    end

    # A real file inside public/ (never outside it, whatever the spelling),
    # or nil.
    def static_file
      path = request_path
      return nil if path.blank? || path == "index.html" || path == "dumbcourse-early.js"
      root_real = PUBLIC_ROOT.realpath
      file =
        begin
          root_real.join(path.delete_prefix("/")).realpath
        rescue StandardError
          nil
        end
      file if file&.file? && file.to_s.start_with?("#{root_real}/")
    end

    def serve_static(file)
      mime =
        case file.extname.downcase
        when ".css"
          "text/css; charset=utf-8"
        when ".js"
          "text/javascript; charset=utf-8"
        when ".json"
          "application/json; charset=utf-8"
        else
          Rack::Mime.mime_type(file.to_s, "application/octet-stream")
        end
      # Versioned URLs (?v=) never change; anything else may.
      response.headers["Cache-Control"] = if params[:v].present?
        "public, max-age=31536000, immutable"
      else
        "public, max-age=86400"
      end
      send_data(File.binread(file), disposition: "inline", type: mime)
    end

    def page_html
      template = File.read(PUBLIC_ROOT.join("index.html"))
      early, = self.class.early_script
      title = SiteSetting.title.to_s
      replacements = {
        "{{TITLE}}" => ERB::Util.html_escape(title),
        "{{ICON}}" => ERB::Util.html_escape(site_icon),
        "{{BASE}}" => ERB::Util.html_escape(app_root),
        "{{VERSION}}" => self.class.asset_version,
        "{{DEFAULT_THEME}}" => ERB::Util.html_escape(SiteSetting.dumbcourse_default_theme.to_s),
        # json_escape turns <, >, & and U+2028/9 into \u escapes, so no
        # value can close the <script> element.
        "{{BOOT}}" => ERB::Util.json_escape(boot_payload.to_json),
        "{{EARLY}}" => early,
      }
      template.gsub(/\{\{[A-Z_]+\}\}/) { |m| replacements.fetch(m, "") }
    end

    def app_root
      "#{Discourse.base_path}#{DiscourseDumbcourse.base_path_with_slash}"
    end

    def site_icon
      SiteIconManager.favicon_url.presence || ""
    rescue StandardError
      ""
    end

    def setting(name)
      SiteSetting.respond_to?(name) ? SiteSetting.public_send(name) : nil
    rescue StandardError
      nil
    end

    def guardian
      @guardian ||= Guardian.new(current_user)
    end

    def boot_payload
      site =
        begin
          SiteSerializer.new(Site.new(guardian), scope: guardian, root: false).as_json
        rescue StandardError => e
          Rails.logger.warn("[Dumbcourse] site data failed: #{e.class}: #{e.message}")
          {}
        end
      site = site.with_indifferent_access

      {
        version: self.class.asset_version,
        basePath: DiscourseDumbcourse.base_path_with_slash,
        subfolder: Discourse.base_path,
        csrf: form_authenticity_token,
        siteTitle: SiteSetting.title,
        siteIcon: site_icon,
        defaultTheme: SiteSetting.dumbcourse_default_theme,
        defaultView: SiteSetting.dumbcourse_default_view,
        paginationEnabled: SiteSetting.dumbcourse_pagination_enabled,
        topicsPerPage: SiteSetting.dumbcourse_topics_per_page,
        showCategoryNames: SiteSetting.dumbcourse_show_category_names,
        topicPostersVisibility: SiteSetting.dumbcourse_topic_posters_visibility,
        onlineGlowEnabled: SiteSetting.dumbcourse_online_glow_enabled,
        languagetoolEnabled: SiteSetting.dumbcourse_languagetool_enabled && current_user.present?,
        pushEnabled: SiteSetting.dumbcourse_push_enabled,
        customEmojis: custom_emojis,
        emojiUrl: Emoji.url_for("EMOJINAME"),
        reactions: reactions,
        noReactionCategoryIds: no_reaction_category_ids,
        reqpmCountryCode: setting(:reqpm_default_country_code).to_s,
        modElectionsEnabled: ::DiscourseModElections.enabled?,
        tagsEnabled: !!SiteSetting.tagging_enabled,
        maxPostLength: SiteSetting.max_post_length,
        minPostLength: SiteSetting.min_post_length,
        minTitleLength: SiteSetting.min_topic_title_length,
        allowUploads: current_user.present?,
        authorizedExtensions: SiteSetting.authorized_extensions,
        notificationTypes: Notification.types,
        notificationTexts: notification_texts,
        flagTypes: flag_types(site),
        categories: categories(site),
        currentUser: boot_user,
        auth: auth_settings(site),
      }
    end

    def boot_user
      user = current_user
      return nil if user.nil?
      reqpm = reqpm_summary(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        avatar_template: user.avatar_template,
        admin: user.admin?,
        moderator: user.moderator?,
        trust_level: user.trust_level,
        can_send_private_messages: guardian.can_send_private_messages?,
        can_review: guardian.can_see_review_queue?,
        reviewable_count: guardian.can_see_review_queue? ? user.reviewable_count : 0,
        unread_notifications: user.unread_notifications,
        unread_high_priority_notifications: user.unread_high_priority_notifications,
        all_unread_notifications_count: user.all_unread_notifications_count,
        new_personal_messages_notifications_count: user.new_personal_messages_notifications_count,
        reqpm_available: reqpm[:available],
        reqpm_incoming_count: reqpm[:incoming_count] || 0,
        mod_election_vote_due: mod_election_vote_due(user),
        can_pair_devices: DiscourseDumbcourse::Pairing.enabled? && !user.is_impersonating,
        second_factor_enabled: user.totp_enabled? || user.security_keys_enabled?,
      }
    rescue StandardError => e
      Rails.logger.warn("[Dumbcourse] user data failed: #{e.class}: #{e.message}")
      nil
    end

    # 1 while Vote Week is open and this member can vote but hasn't.
    def mod_election_vote_due(user)
      return 0 unless ::DiscourseModElections.enabled?
      summary = ::DiscourseModElections::Presenter.current_user_summary(user)
      summary && summary[:voter] && !summary[:voted] ? 1 : 0
    rescue StandardError
      0
    end

    def reqpm_summary(user)
      ::DiscourseReqpm::Presenter.current_user_summary(user)
    rescue StandardError
      { available: false }
    end

    # Custom-emoji overrides (Admin → Customize → Emoji and plugin emoji),
    # so reactions and emoji use the same images as the full site.
    def custom_emojis
      Emoji
        .custom
        .each_with_object({}) do |e, h|
          url =
            (
              begin
                e.url
              rescue StandardError
                nil
              end
            )
          h[e.name] = url if url.present?
        end
    rescue StandardError
      {}
    end

    def reactions
      enabled = !!setting(:discourse_reactions_enabled)
      {
        enabled: enabled,
        main: setting(:discourse_reactions_reaction_for_like).to_s.presence || "heart",
        list:
          (
            if enabled
              setting(:discourse_reactions_enabled_reactions).to_s.split("|").reject(&:blank?)
            else
              []
            end
          ),
      }
    end

    def no_reaction_category_ids
      ::DiscourseNoLikes.restricted_category_ids
    rescue StandardError
      []
    end

    # Text for this plugin's own custom notifications, so Dumbcourse shows
    # the same wording as the full site.
    NOTIFICATION_KEYS = %w[
      reqpm.notifications.request
      reqpm.notifications.shared
      mod_elections.notifications.on_ballot
      mod_elections.notifications.voting_open
      mod_elections.notifications.reminder
      mod_elections.notifications.closed
      mod_elections.notifications.results
      mod_elections.notifications.disqualified
      mod_elections.notifications.seat_filled
      discourse_mod_categories.whisper.whisper_notification
      discourse_mod_categories.note_notification
      discourse_mod_categories.note_reply_notification
    ].freeze

    def notification_texts
      NOTIFICATION_KEYS.each_with_object({}) do |key, h|
        text = I18n.t("js.#{key}", default: "")
        h[key] = text if text.is_a?(String) && text.present?
      end
    end

    def flag_types(site)
      Array(site[:post_action_types])
        .select { |t| t[:is_flag] }
        .map do |t|
          {
            id: t[:id],
            name: t[:name],
            description: t[:description],
            is_custom_flag: !!t[:is_custom_flag],
            require_message: !!t[:require_message],
          }
        end
    end

    def categories(site)
      Array(site[:categories]).map do |c|
        c.slice(
          :id,
          :name,
          :slug,
          :color,
          :text_color,
          :parent_category_id,
          :description_text,
          :topic_count,
          :permission,
          :read_restricted,
          :position,
          :notification_level,
          :subcategory_ids,
        )
      end
    end

    def auth_settings(site)
      local = !!SiteSetting.enable_local_logins
      {
        local: local,
        emailLink: local && !!SiteSetting.enable_local_logins_via_email,
        emailCode: local && email_codes_enabled?,
        pairing: DiscourseDumbcourse::Pairing.enabled?,
        signup: local && !!SiteSetting.allow_new_registrations,
        inviteOnly: !!SiteSetting.invite_only,
        mustApprove: !!SiteSetting.must_approve_users,
        fullNameRequired: setting(:full_name_requirement).to_s == "required_at_signup",
        fullNameVisible:
          !!SiteSetting.enable_names && setting(:full_name_requirement).to_s != "hidden_at_signup",
        usernameMin: SiteSetting.min_username_length,
        usernameMax: SiteSetting.max_username_length,
        passwordMin: SiteSetting.min_password_length,
        userFields:
          Array(site[:user_fields]).map do |f|
            f.slice(:id, :name, :description, :field_type, :required, :show_on_signup, :options)
          end,
        providers:
          Array(site[:auth_providers]).map do |p|
            name = p[:name].to_s
            {
              name: name,
              title:
                p[:title_override].presence || p[:pretty_name_override].presence ||
                  I18n.t("js.login.#{name}.name", default: name.titleize),
            }
          end,
        hcaptchaSiteKey:
          setting(:discourse_captcha_enabled) ? setting(:hcaptcha_site_key).to_s : "",
      }
    end

    # Discourse's emailed one-time codes (an upcoming change on newer
    # versions); off wherever the forum hasn't turned them on.
    def email_codes_enabled?
      return false unless SiteSetting.respond_to?(:enable_local_logins_via_code)
      if defined?(::UpcomingChanges) && ::UpcomingChanges.respond_to?(:enabled_for_user?)
        ::UpcomingChanges.enabled_for_user?(:enable_local_logins_via_code, current_user)
      else
        !!SiteSetting.enable_local_logins_via_code
      end
    rescue StandardError
      false
    end

    # Signed-out visitors go to the sign-in screen, remembering where they
    # were headed. The app root and the public screens render as usual.
    def redirect_anonymous_to_login
      return if current_user.present?
      path = request_path
      return if path.blank? || path.match?(PUBLIC_SCREENS) || static_file

      redirect_to "#{app_root}/login?#{{ next: "/#{path}" }.to_query}"
    end

    def ensure_enabled
      raise Discourse::NotFound unless DiscourseDumbcourse.enabled?
    end

    # A strict policy: scripts only from this site (plus the one inline
    # theme script, by hash), no framing by other sites, no MIME sniffing.
    # Old browsers ignore CSP; they still get the other headers.
    def security_headers
      _, early_hash = self.class.early_script
      scripts = ["'self'", "'#{early_hash}'"]
      frames = ["'none'"]
      if setting(:discourse_captcha_enabled)
        scripts += %w[https://hcaptcha.com https://*.hcaptcha.com]
        frames = %w[https://hcaptcha.com https://*.hcaptcha.com]
      end
      policy = [
        "default-src 'self'",
        "script-src #{scripts.join(" ")}",
        "style-src 'self' 'unsafe-inline'",
        "img-src * data: blob:",
        "media-src * data: blob:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "frame-src #{frames.join(" ")}",
        "object-src 'none'",
        "base-uri 'none'",
        # Social sign-in posts to /auth/:provider, which redirects to the
        # provider's own site.
        "form-action 'self' https:",
        "frame-ancestors 'self'",
      ].join("; ")
      response.headers["Content-Security-Policy"] = policy
      response.headers["X-Frame-Options"] = "SAMEORIGIN"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    end
  end
end
