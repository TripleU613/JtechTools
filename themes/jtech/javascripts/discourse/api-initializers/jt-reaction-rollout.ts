import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtReactionRollout, {
  notePress,
} from "../components/jt-reaction-rollout.gts";

interface PostMenuDag {
  add(key: string, value: unknown, position?: { after?: string }): void;
}

interface ReactionSettings {
  discourse_reactions_enabled?: boolean;
  discourse_reactions_enabled_reactions?: string;
  discourse_reactions_reaction_for_like?: string;
  discourse_reactions_allow_any_emoji?: boolean;
  enable_emoji?: boolean;
}

// How many buttons the plugin's picker shows: the enabled reactions, the
// like's own if it isn't among them, and the emoji picker when any emoji is
// allowed. The row is never wider than that.
function pickerSize(s: ReactionSettings): number {
  const reactions = (s.discourse_reactions_enabled_reactions || "")
    .split("|")
    .filter(Boolean);
  const like = s.discourse_reactions_reaction_for_like;
  return (
    reactions.length +
    (like && !reactions.includes(like) ? 1 : 0) +
    (s.discourse_reactions_allow_any_emoji ? 1 : 0)
  );
}

// A row is only ever on screen while someone points at it, so its wheel
// listener goes on when the mouse first comes over it.
const scrolled = new WeakSet<Element>();

function wheelScrollsSideways(event: PointerEvent) {
  if (event.pointerType !== "mouse") {
    return;
  }
  const row = (event.target as Element | null)?.closest?.(
    ".discourse-reactions-picker-container"
  );
  if (!row || scrolled.has(row)) {
    return;
  }
  scrolled.add(row);
  row.addEventListener(
    "wheel",
    (e) => {
      const wheel = e as WheelEvent;
      if (Math.abs(wheel.deltaY) <= Math.abs(wheel.deltaX)) {
        return;
      }
      const end = row.scrollWidth - row.clientWidth;
      const step = wheel.deltaY * (wheel.deltaMode === 1 ? 16 : 1);
      // at either end the page scrolls as usual
      if (
        (step < 0 && row.scrollLeft <= 0) ||
        (step > 0 && row.scrollLeft >= end)
      ) {
        return;
      }
      row.scrollLeft += step;
      wheel.preventDefault();
    },
    { passive: false }
  );
}

// The Reactions plugin's picker as a row that rolls out sideways beside the
// heart (setting reaction_rollout) instead of a box over the post. The
// styles (jt-post-chrome) make the row; this adds the button that opens it
// on touch screens (and lets it see presses before the plugin does), and has
// a mouse wheel scroll it.
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup(
    "service:site-settings"
  ) as ReactionSettings;
  if (
    !settings.reaction_rollout ||
    !siteSettings.discourse_reactions_enabled ||
    !siteSettings.enable_emoji
  ) {
    return;
  }
  const root = document.documentElement;
  root.classList.add("jt-reaction-rollout");
  root.style.setProperty("--jt-rx-count", String(pickerSize(siteSettings)));

  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag }: { value: PostMenuDag }) => {
      dag.add("jt-reaction-rollout", JtReactionRollout, { after: "like" });
    }
  );

  document.addEventListener("pointerover", wheelScrollsSideways, {
    passive: true,
  });
  document.addEventListener("pointerdown", notePress, {
    capture: true,
    passive: true,
  });
});
