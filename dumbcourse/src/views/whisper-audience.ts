// Who a staff whisper is for (this plugin's whispers): a member, a group or
// the holders of a badge, as the full site's whisper button picks them. Staff
// always see it too.

import { get } from "../api.ts";
import { settings } from "../config.ts";
import { toast } from "../ui/layers.ts";
import type { Whisper } from "./composer.ts";
import { askUsername, choose, fail } from "./staff-common.ts";

export function chooseWhisperAudience(done: (w: Whisper) => void): void {
  const choices = [
    { label: "A member…", value: "user" },
    { label: "A group…", value: "group" },
  ];
  if (settings.staff && settings.staff.whisperBadges)
    choices.push({ label: "Holders of a badge…", value: "badge" });
  choose("Whisper to", choices, (kind) => {
    if (kind === "user")
      askUsername("Whisper to", (username) =>
        get<{ user?: { id: number; username: string } }>(
          `/u/${encodeURIComponent(username)}.json`
        ).then((d) => {
          if (!d.user) return;
          done({
            core: false,
            userIds: [d.user.id],
            label: "@" + d.user.username + " and staff",
          });
        }, fail)
      );
    else if (kind === "group")
      askUsername(
        "Whisper to a group",
        (name) =>
          get<{ group?: { id: number; name: string } }>(
            `/groups/${encodeURIComponent(name)}.json`
          ).then((d) => {
            if (!d.group) return;
            done({
              core: false,
              userIds: [],
              groupIds: [d.group.id],
              label: d.group.name + " and staff",
            });
          }, fail),
        "Group name"
      );
    else
      get<{
        badges?: Array<{ id: number; name: string; enabled?: boolean }>;
      }>("/badges.json").then((d) => {
        const badges = (d.badges || []).filter((b) => b.enabled !== false);
        if (!badges.length) {
          toast("No badges.", "error");
          return;
        }
        choose(
          "Whisper to holders of",
          badges.map((b) => ({ label: b.name, value: String(b.id) })),
          (id) => {
            const b = badges.filter((x) => String(x.id) === id)[0];
            if (b)
              done({
                core: false,
                userIds: [],
                badgeIds: [b.id],
                label: "holders of " + b.name + " and staff",
              });
          }
        );
      }, fail);
  });
}
