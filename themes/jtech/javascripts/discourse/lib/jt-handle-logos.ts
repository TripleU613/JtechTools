// Handles that get their logo before a mention (setting handle_logos).
// Each one also needs assets/handles/<handle>.svg, an about.json asset
// named handle-<handle> and a line in stylesheets/jt-handles.scss.
export const HANDLE_LOGOS: ReadonlySet<string> = new Set([
  "claude",
  "chatgpt",
  "anthropic",
  "microsoft",
  "apple",
  "meta",
  "samsung",
  "nvidia",
  "intel",
  "tesla",
  "spacex",
  "jtechforums",
  "groupme",
  "github",
  "discourse",
  "linux",
  "android",
  "24six",
  "zing",
  "naki",
  "cloudflare",
  "python",
]);
