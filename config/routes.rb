# frozen_string_literal: true

# Routes for the Jtech bundle. Each sub-plugin's URLs are appended directly
# under Discourse::Application — we don't mount the sub-plugins' Rails
# engines.
#
# Why: mounting `DiscourseModCategories::Engine` reliably raised
#   ArgumentError: Invalid route name, already in use: 'discourse_mod_categories'
# at boot, no matter what `as:` we passed or whether the mount was inside
# `routes.draw` or `routes.append`. Something earlier in the boot pipeline
# (Discourse's plugin loader, presumably, since this engine module is also
# referenced from sub_plugins/mod_categories.rb's PluginStore namespace and
# locale tree) registers the helper name first, so a second mount collides.
# Bypassing the engine mount avoids the collision and the route table is
# functionally identical — the controllers under
# `app/controllers/<namespace>/` are autoloaded by Rails regardless of
# whether their parent module is mounted as an engine.
#
# Sub-plugins that don't register routes — Dislike, Another SMTP, Mini-mod —
# rely on Discourse's existing routes via Guardian overrides and event hooks,
# so they have no entries here.

# ── Mod-categories ─────────────────────────────────────────────────────────
Discourse::Application.routes.append do
  scope "/discourse-mod-categories",
        module: "discourse_mod_categories",
        as: :discourse_mod_categories do
    put "/topic/:topic_id" => "messages#update_topic"
    put "/category/:category_id" => "messages#update_category"
    post "/topic/:topic_id/note-reply" => "messages#add_note_reply"
    get "/notification-types" => "notification_types#index"
    put "/topic/:topic_id/note-reply" => "messages#update_note_reply"
    delete "/topic/:topic_id/note-reply" => "messages#delete_note_reply"
    delete "/topic/:topic_id/note" => "messages#delete_note"
    post "/topic/:topic_id/whisper-participant" => "messages#add_whisper_participant"
    get "/badge-members/:badge_id" => "messages#badge_members"
    get "/notes-feed" => "messages#notes_feed"
    post "/notes-feed/seen" => "messages#notes_feed_seen"
    post "/topic/:topic_id/notifications/seen" => "messages#mark_topic_notifications_seen"
    post "/review/notifications/seen" => "messages#mark_review_notifications_seen"
    post "/topic/:topic_id/note-view" => "messages#record_note_view"
    put "/post/:id/whisper" => "messages#update_post_whisper"
    get "/post/:id/viewers" => "messages#post_viewers"
    get "/checklist" => "checklist#show"
    get "/checklist/owed" => "checklist#owed"
    put "/checklist" => "checklist#update"
    post "/checklist/accept" => "checklist#accept"
    post "/checklist/require-reaccept" => "checklist#require_reaccept"
    post "/checklist/targeted" => "checklist#create_targeted"
    put "/checklist/targeted/:id" => "checklist#update_targeted"
    delete "/checklist/targeted/:id" => "checklist#delete_targeted"
    get "/topic/:topic_id/prompt-checklist" => "checklist#show_topic"
    put "/topic/:topic_id/prompt-checklist" => "checklist#update_topic"
    delete "/topic/:topic_id/prompt-checklist" => "checklist#delete_topic"
    get "/slow-mode" => "user_slow_mode#show"
    put "/user/:user_id/slow-mode" => "user_slow_mode#update"
    delete "/user/:user_id/slow-mode" => "user_slow_mode#destroy"
  end
end

# ── Disteleplus ────────────────────────────────────────────────────────────
Discourse::Application.routes.append do
  scope "/jtech-disteleplus", module: "discourse_disteleplus", as: :disteleplus do
    # Telegram Bot API webhook receiver. No session — authenticated by the
    # X-Telegram-Bot-Api-Secret-Token header set via setWebhook.
    post "/telegram/webhook" => "webhook#receive"
    # Server-rendered entry point for the Ember route, so a hard load or a
    # shared link to /disteleplus boots the app instead of 404ing.
    get "/conversation" => "conversation#show"
    get "/messages" => "conversation#index"
    post "/messages" => "conversation#create"
    put "/messages/:id" => "conversation#update"
    delete "/messages/:id" => "conversation#destroy"
    put "/messages/:id/reactions/:emoji" => "conversation#add_reaction"
    delete "/messages/:id/reactions/:emoji" => "conversation#remove_reaction"
    post "/read" => "conversation#read"
    get "/search" => "conversation#search"
    post "/typing" => "conversation#typing"
    get "/read-states" => "conversation#read_states"
    post "/messages/:id/listened" => "conversation#listened"
    get "/legacy-import" => "legacy_import#show"
    post "/legacy-import" => "legacy_import#create"
  end
end

Discourse::Application.routes.append do
  get "/disteleplus" => "discourse_disteleplus/conversation#page"
end

# ── REQ-PM (contact exchange) ─────────────────────────────────────────────
Discourse::Application.routes.append do
  scope "/jtech-reqpm", module: "discourse_reqpm", as: :reqpm, defaults: { format: :json } do
    get "/card" => "card#show"
    post "/card/methods" => "card#create"
    put "/card/methods/order" => "card#reorder"
    put "/card/methods/:id" => "card#update"
    delete "/card/methods/:id" => "card#destroy"
    put "/card/preferences" => "card#preferences"
    post "/card/setup/snooze" => "card#snooze_setup"
    post "/card/setup/decline" => "card#decline_setup"

    get "/inbox" => "exchange#inbox"
    get "/users/:username" => "exchange#relationship",
        :constraints => {
          username: RouteFormat.username,
        }
    post "/requests" => "exchange#create_request"
    post "/requests/:id/decline" => "exchange#decline_request"
    delete "/requests/:id" => "exchange#cancel_request"
    post "/shares" => "exchange#share"
    delete "/shares/:username" => "exchange#revoke",
           :constraints => {
             username: RouteFormat.username,
           }
    delete "/received/:username" => "exchange#forget",
           :constraints => {
             username: RouteFormat.username,
           }
  end

  # Ember entry point (hard loads and links from notifications).
  get "/reqpm" => "discourse_reqpm/card#page"
end

# ── Listing format ──────────────────────────────────────────────────────────
Discourse::Application.routes.append do
  scope "/jtech-listing-format",
        module: "discourse_listing_format",
        as: :listing_format,
        defaults: {
          format: :json,
        } do
    put "/posts/:id/sold" => "listings#sold"
  end
end

# ── Jtech admin maintenance actions (buttons on the plugin tabs) ───────────
Discourse::Application.routes.append do
  post "/admin/plugins/jtech-tools/actions/:id" => "jtech/admin_actions#run",
       :constraints => AdminConstraint.new,
       :defaults => {
         format: :json,
       }

  # The plugin's admin tabs (/admin/plugins/jtech-tools/mod, /disteleplus, …)
  # are Ember child routes of adminPlugins.show; core only serves the bare
  # plugin page and /settings, so a hard load or shared link to a tab 404s
  # without this. admin#index renders the admin app shell exactly as core
  # does for its own admin pages. Core's earlier /settings route still wins
  # for that path since it is drawn first.
  namespace :admin, constraints: StaffConstraint.new do
    get "plugins/jtech-tools/*tab" => "admin#index"
  end
end

# ── Dumbcourse ─────────────────────────────────────────────────────────────
class DiscourseDumbcourseBasePathConstraint
  # Rails has NOT extracted path params when request constraints run — both
  # req.path_parameters and req.params carry only the route default here, so
  # comparing either to base_path was always true and the catch-all swallowed
  # every unknown multi-segment GET on the site (proven by
  # /admin/plugins/jtech-tools/mod being served by Dumbcourse's AppController).
  # The request path itself is the only trustworthy source at this stage.
  def matches?(req)
    req.path.split("/")[1].to_s == DiscourseDumbcourse.base_path
  end
end

Discourse::Application.routes.append do
  constraints DiscourseDumbcourseBasePathConstraint.new do
    scope "/:dumbcourse_base_path",
          module: "discourse_dumbcourse",
          as: :discourse_dumbcourse,
          defaults: {
            dumbcourse_base_path: DiscourseDumbcourse.base_path,
          } do
      post "/hcaptcha" => "app#hcaptcha"

      # Sign in with another device, and the composer preview.
      scope "/auth/pair", defaults: { format: :json } do
        post "/" => "pair#create"
        get "/poll" => "pair#poll"
        get "/lookup" => "pair#lookup"
        post "/approve" => "pair#approve"
        post "/deny" => "pair#deny"
      end
      post "/api/preview" => "api#preview", :defaults => { format: :json }

      # Push notification endpoints (must be before catch-all)
      scope "/push", defaults: { format: :json } do
        get "/info" => "push#server_info"
        post "/register" => "push#register"
        delete "/unregister" => "push#unregister"
        get "/status" => "push#status"
        get "/preferences" => "push#preferences"
        put "/preferences" => "push#update_preferences"
        post "/test" => "push#test_push"
      end

      # SSE / ntfy endpoints — must be before the catch-all so stale clients
      # don't get redirected to /login.
      get "/push/sse/:topic" => "sse#stream"
      get "/ntfy/:topic/sse" => "sse#stream"
      get "/ntfy/*path" => "sse#stream"

      # LanguageTool proxy endpoint
      post "/languagetool/check" => "languagetool#check"

      # Main app routes (catch-all) — exclude push and ntfy paths.
      # The lambda re-checks the base path itself: a route-level non-hash
      # :constraints REPLACES the scope-level constraint object in Rails'
      # scope merging, so without the start_with? guard this catch-all
      # matched every unknown multi-segment GET on the site.
      get "/" => "app#show"
      get "/*path" => "app#show",
          :constraints => ->(req) do
            base = DiscourseDumbcourse.base_path_with_slash
            req.path.start_with?("#{base}/") && !req.path.start_with?("#{base}/push") &&
              !req.path.start_with?("#{base}/ntfy")
          end
    end
  end
end

# ── Mod elections ───────────────────────────────────────────────────────────
Discourse::Application.routes.append do
  scope "/jtech-elections",
        module: "discourse_mod_elections",
        as: :mod_elections,
        defaults: {
          format: :json,
        } do
    get "/current" => "elections#show"
    post "/:id/candidacy" => "elections#run"
    put "/:id/candidacy" => "elections#update_candidacy"
    delete "/:id/candidacy" => "elections#withdraw"
    put "/:id/ballot" => "elections#vote"
    delete "/:id/ballot" => "elections#clear_ballot"

    # Admin tab. Not under /admin/plugins/jtech-tools/, whose GETs are the
    # Ember tab catch-all above.
    scope "/admin", constraints: AdminConstraint.new do
      get "/" => "admin#index"
      post "/elections" => "admin#create"
      get "/seats" => "admin#seats"
      post "/seats/:candidate_id/vacate" => "admin#vacate"
      get "/seats/countback" => "admin#countback"
      post "/seats/fill" => "admin#fill"
      get "/elections/:id" => "admin#show"
      put "/elections/:id" => "admin#update"
      post "/elections/:id/end-phase" => "admin#end_phase"
      post "/elections/:id/cancel" => "admin#cancel"
      post "/elections/:id/candidates/:candidate_id/disqualify" => "admin#disqualify"
      post "/elections/:id/candidates/:candidate_id/reinstate" => "admin#reinstate"
      get "/elections/:id/ip-report" => "admin#ip_report"
      post "/elections/:id/ballots/:ballot_id/void" => "admin#void_ballot"
      post "/elections/:id/ballots/:ballot_id/restore" => "admin#restore_ballot"
      post "/elections/:id/preview" => "admin#preview"
      post "/elections/:id/publish" => "admin#publish"
    end
  end

  # Ember entry point (hard loads and links from notifications).
  get "/elections" => "discourse_mod_elections/elections#page"
end
