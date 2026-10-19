import { settings, themePrefix } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import type ModalService from "discourse/services/modal";
import type SiteSettingsService from "discourse/services/site-settings";
import JtVoiceRecorder from "../components/modal/jt-voice-recorder.gts";
import { voiceFormat } from "../lib/jt-voice.ts";

interface Toolbar {
  addButton(button: {
    id: string;
    group: string;
    icon: string;
    title: string;
    perform: () => void;
  }): void;
}

// A microphone in the composer's toolbar (setting voice_recorder), where the
// browser can record and the forum takes the recording's file type.
export default apiInitializer((api) => {
  const format = voiceFormat();
  if (!settings.voice_recorder || !format) {
    return;
  }
  const siteSettings = api.container.lookup(
    "service:site-settings"
  ) as SiteSettingsService & { authorized_extensions: string };
  const allowed = siteSettings.authorized_extensions.toLowerCase().split("|");
  if (!allowed.includes("*") && !allowed.includes(format.ext)) {
    return;
  }
  const modal = api.container.lookup("service:modal") as ModalService;

  api.onToolbarCreate((toolbar: Toolbar) => {
    toolbar.addButton({
      id: "jt-voice",
      group: "extras",
      icon: "microphone",
      title: themePrefix("jt.voice.button"),
      perform: () => modal.show(JtVoiceRecorder, undefined),
    });
  });
});
