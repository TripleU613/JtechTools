# Translator tweaks

For sites running the official **discourse-translator** plugin with Google. It points the plugin's Google requests at a proxy you run (`translator_tweaks_worker_url`), for example to spread Google's per-IP quota. The proxy receives the site's Google API key and every post it translates, so only use one you control. Changes need an app restart.

`scripts/translator_backfill_foreign_detection.rb` detects the language of old non-Latin posts that never had it detected.

Newer Discourse translates through core content localization and Discourse AI, which don't need this module.

## Settings

Admin → Plugins → Jtech Tools → **Translator**. The full text of each setting is shown next to it in the admin.

| Setting | Default | What it does |
| --- | --- | --- |
| `translator_tweaks_enabled` | `false` | Master switch for the Jtech tweak to the upstream discourse-translator plugin. |
| `translator_tweaks_worker_url` | `https://google-translate-worker.abest…` | Base URL the bundled Google translate provider is pointed at instead of translation.googleapis.com — include the full /language/translate/v2 path; /detect and /languages are appended to it. |

[← All features](../README.md#features)
