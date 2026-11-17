# How the plugin is put together

Jtech Tools is one Discourse plugin made of several modules. Each module was once its own plugin, and still keeps its own Ruby namespace, settings and on/off switch.

## Loading

`plugin.rb` declares the plugin (name, version, the `rwordnet` gem, the master switch `jtech_enabled`). It then reads each file in `sub_plugins/` and evaluates it in the plugin's own context:

```ruby
%w[dislike another_smtp mini_mod mod_categories dumbcourse translator_tweaks
   smart_search popup_notifications disteleplus reqpm listing_format
   jtech_theme mod_elections].each do |sub|
  instance_eval(File.read("sub_plugins/#{sub}.rb"), ...)
end
```

So a sub-plugin file reads like any `plugin.rb` body: `after_initialize`, `on(:event)`, `register_asset`, `add_to_serializer`, `reloadable_patch` and the rest all work.

## Where things live

| Path | What's there |
| --- | --- |
| `plugin.rb` | Plugin header, gem, master switch, the sub-plugin load list |
| `sub_plugins/<module>.rb` | Each module's wiring: hooks, patches, serializers |
| `lib/discourse_<module>/` | Plain Ruby for each module (Guardian extensions, services, core patches) |
| `app/controllers/`, `app/models/`, `app/jobs/`, `app/services/` | Standard Rails pieces, namespaced per module |
| `config/settings.yml` | One block per admin tab (`jtech_dislike`, `jtech_mod_whispers`, …) |
| `config/locales/server.en.yml` | Setting descriptions, server strings |
| `config/locales/client.en.yml` | Browser strings, admin tab names |
| `config/routes.rb` | Every module's routes |
| `db/migrate/` | Tables and one-off data fixes |
| `assets/javascripts/discourse/` | The Discourse frontend: TypeScript components, connectors, initializers |
| `admin/assets/javascripts/` | The Jtech Tools admin tabs |
| `assets/stylesheets/` | SCSS |
| `dumbcourse/` | The Dumbcourse app source (TypeScript, built to `public/`) — see [dumbcourse.md](dumbcourse.md) |
| `public/` | Built Dumbcourse files, committed |
| `scripts/` | One-off `rails runner` scripts (Ruby); theme sync and checks (`scripts/theme/`); the README images (`pnpm readme:images`) |
| `spec/` | RSpec: `lib/`, `requests/`, `jobs/`, `system/` |
| `types/` | TypeScript declarations for Discourse modules |

## Switches

Every module has an `enabled?` helper that checks both its own switch and `jtech_enabled`, for example `DiscourseMiniMod.enabled?`. Discourse turns off a disabled plugin's event hooks, serializers and assets by itself, but not its core-class patches or scheduled jobs. So every patch and job goes through the helper. `spec/lib/jtech_master_switch_spec.rb` checks this.

Some things deliberately ignore the switches. Whispers stay private whatever is switched off, because turning a feature off must never make hidden posts public.

## Permissions

Patches to `Guardian` add rights on top of core (`return true if super`) or take them away. Rules every patch follows:

- A grant never reaches something core keeps hidden from that user. Check `can_see_category?` / `can_see_topic?` as well as the grant.
- A controller that loads a record by id checks the caller can see it before doing anything with it.
- Anything sent to a group of people (alerts, MessageBus, push) goes only to those who can see what it's about.
- Core already has a setting for it? Use core's.

## Admin

The Jtech Tools admin page (`/admin/plugins/jtech-tools`) has one tab per module. Each tab shows the matching settings block via `AdminAreaSettings`. Maintenance actions are buttons that post to `Jtech::AdminActionsController`.
