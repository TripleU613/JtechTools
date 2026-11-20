import { withPluginApi } from "discourse/lib/plugin-api";

interface PickerReaction {
  id: string;
  isUsed?: boolean;
}

// Reaction levels (lib/discourse_reaction_levels.rb): discourse-reactions'
// picker offers only the reactions this person's trust level has unlocked
// (currentUser.jt_reactions, absent when nothing is held back for them).
// A reaction they already gave on the post stays, so they can take it back.
// The server refuses the rest anyway.
export default {
  name: "jtech-reaction-levels",

  initialize() {
    withPluginApi((api) => {
      api.modifyClass(
        "component:discourse-reactions-picker",
        (Superclass) =>
          class extends Superclass {
            get reactionInfo(): PickerReaction[] {
              const all = super.reactionInfo as PickerReaction[];
              const allowed = (
                this.currentUser as { jt_reactions?: string[] } | null
              )?.jt_reactions;
              if (!allowed) {
                return all;
              }
              return all.filter(
                (reaction) => reaction.isUsed || allowed.includes(reaction.id)
              );
            }
          },
        undefined
      );
    });
  },
};
