import Component from "@glimmer/component";
import { action } from "@ember/object";
import { schedule } from "@ember/runloop";
import { themePrefix } from "virtual:theme";
import DButton from "discourse/ui-kit/d-button";

interface ReactionPost {
  user_id: number;
  likeAction?: { canToggle?: boolean };
  current_user_reaction?: { can_undo?: boolean } | null;
  topic?: { archived?: boolean };
}

interface JtReactionRolloutSignature {
  Args: { post: ReactionPost };
  Element: HTMLButtonElement | HTMLAnchorElement;
}

const OPEN_ROW = ".discourse-reactions-picker.is-expanded";
const BUTTON = ".post-action-menu__jt-reaction-rollout";

// The plugin shuts its row on any press outside it, this button's included,
// before the click comes. The initializer has this see each press first
// (capturing), so the click after a press on an open row knows it was a
// close.
let pressedOnOpenRow: Element | null = null;

export function notePress(event: PointerEvent) {
  const button = (event.target as Element | null)?.closest?.(BUTTON);
  pressedOnOpenRow = button?.closest(".actions")?.querySelector(OPEN_ROW)
    ? button
    : null;
}

// Opens the Reactions plugin's row of reactions with a tap, on screens with
// no pointer to rest on the heart (the styles show it only there). The
// plugin opens its picker when a mouse comes over the heart, so the button
// hands it that, and the plugin goes on doing the rest: what can be picked,
// counts, undo and errors.
export default class JtReactionRollout extends Component<JtReactionRolloutSignature> {
  // The same posts the plugin offers its picker on.
  static shouldRender(
    args: { post: ReactionPost },
    helper: { currentUser?: { id: number } | null }
  ) {
    const { post } = args;
    const user = helper.currentUser;
    if (!user) {
      return !post.topic?.archived;
    }
    return (
      post.user_id !== user.id &&
      !!post.likeAction?.canToggle &&
      post.current_user_reaction?.can_undo !== false
    );
  }

  @action
  toggle(_param: undefined, event: Event) {
    const button = (event.target as Element | null)?.closest(BUTTON);
    const actions = button?.closest(".actions");
    const heart = actions?.querySelector(
      ".discourse-reactions-reaction-button"
    );
    if (!button || !actions || !heart) {
      return;
    }
    if (pressedOnOpenRow === button) {
      pressedOnOpenRow = null;
      return;
    }
    if (actions.querySelector(OPEN_ROW)) {
      // from the keyboard, where no press came first
      document.body.dispatchEvent(
        new PointerEvent("pointerdown", { bubbles: true })
      );
      return;
    }
    heart.dispatchEvent(
      new PointerEvent("pointerover", { bubbles: true, pointerType: "mouse" })
    );
    // Enter or Space: on into the row, which comes before the heart
    if ((event as UIEvent).detail === 0) {
      schedule("afterRender", () =>
        actions
          .querySelector<HTMLElement>(`${OPEN_ROW} .pickable-reaction`)
          ?.focus()
      );
    }
  }

  <template>
    <DButton
      class="post-action-menu__jt-reaction-rollout"
      ...attributes
      @action={{this.toggle}}
      @ariaLabel={{themePrefix "jt.reaction_rollout.open"}}
      @forwardEvent={{true}}
      @icon="discourse-emojis"
      @title={{themePrefix "jt.reaction_rollout.open"}}
    />
  </template>
}
