import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import { themePrefix } from "virtual:theme";
import type AppEventsService from "discourse/services/app-events";
import type SiteSettingsService from "discourse/services/site-settings";
import DButton from "discourse/ui-kit/d-button";
import DModalBase from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import { clock, VOICE_BITRATE, voiceFormat } from "../../lib/jt-voice.ts";

const DModal = DModalBase as unknown as ComponentLike<{
  Element: HTMLDivElement | HTMLFormElement;
  Args: { closeModal?: () => void; title?: string };
  Blocks: { body: []; footer: [] };
}>;

type Phase = "idle" | "recording" | "recorded";

interface JtVoiceRecorderSignature {
  Args: { closeModal: () => void };
}

// Record a voice message in the composer (setting voice_recorder; it
// replaces the Voice Recorder component): record, listen back, then add it
// to the post through the composer's own uploader, like a dropped file. A
// recording stops by itself before it would pass the attachment size limit.
export default class JtVoiceRecorder extends Component<JtVoiceRecorderSignature> {
  @service declare appEvents: AppEventsService;
  @service
  declare siteSettings: SiteSettingsService & {
    max_attachment_size_kb: number;
  };

  @tracked phase: Phase = "idle";
  @tracked seconds = 0;
  @tracked error: string | null = null;
  @tracked previewUrl: string | null = null;

  format = voiceFormat();
  recorder?: MediaRecorder;
  stream?: MediaStream;
  chunks: Blob[] = [];
  recording?: Blob;
  timer?: number;

  willDestroy() {
    super.willDestroy();
    this.halt();
    this.release();
    this.revoke();
  }

  get maxSeconds() {
    // 90% of the limit, for the container's own bytes
    const bits = this.siteSettings.max_attachment_size_kb * 1024 * 8 * 0.9;
    return Math.max(10, Math.floor(bits / VOICE_BITRATE));
  }

  get isIdle() {
    return this.phase === "idle";
  }

  get isRecording() {
    return this.phase === "recording";
  }

  get elapsed() {
    return clock(this.seconds);
  }

  get limit() {
    return clock(this.maxSeconds);
  }

  @action
  async record() {
    const format = this.format;
    if (!format) {
      return;
    }
    this.error = null;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (error) {
      const blocked = (error as DOMException)?.name === "NotAllowedError";
      this.error = i18n(
        themePrefix(blocked ? "jt.voice.blocked" : "jt.voice.no_microphone")
      );
      return;
    }
    this.chunks = [];
    const recorder = new MediaRecorder(this.stream, {
      mimeType: format.mime,
      audioBitsPerSecond: VOICE_BITRATE,
    });
    recorder.addEventListener("dataavailable", (event) => {
      if (event.data.size) {
        this.chunks.push(event.data);
      }
    });
    recorder.addEventListener("stop", () => this.finish());
    recorder.start(1000);
    this.recorder = recorder;
    this.seconds = 0;
    this.phase = "recording";
    this.timer = window.setInterval(() => {
      this.seconds++;
      if (this.seconds >= this.maxSeconds) {
        this.stop();
      }
    }, 1000);
  }

  @action
  stop() {
    this.halt();
    this.release();
  }

  @action
  again() {
    this.revoke();
    this.recording = undefined;
    this.phase = "idle";
    this.record();
  }

  @action
  add() {
    if (!this.recording || !this.format) {
      return;
    }
    const type = this.format.mime.split(";")[0];
    const file = new File(
      [this.recording],
      `voice-message.${this.format.ext}`,
      {
        type,
      }
    );
    this.appEvents.trigger("composer:add-files", [file]);
    this.args.closeModal();
  }

  finish() {
    if (!this.format || this.isDestroying) {
      return;
    }
    this.recording = new Blob(this.chunks, {
      type: this.format.mime.split(";")[0],
    });
    this.revoke();
    this.previewUrl = URL.createObjectURL(this.recording);
    this.phase = "recorded";
  }

  halt() {
    window.clearInterval(this.timer);
    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.stop();
    }
  }

  // the browser's "recording" mark goes once the tracks stop
  release() {
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = undefined;
  }

  revoke() {
    if (this.previewUrl) {
      URL.revokeObjectURL(this.previewUrl);
      this.previewUrl = null;
    }
  }

  <template>
    <DModal
      class="jt-voice"
      @closeModal={{@closeModal}}
      @title={{i18n (themePrefix "jt.voice.title")}}
    >
      <:body>
        {{#if this.error}}
          <p class="jt-voice__error" role="alert">{{this.error}}</p>
        {{/if}}
        {{#if this.previewUrl}}
          <audio
            class="jt-voice__preview"
            controls
            src={{this.previewUrl}}
          ></audio>
        {{else}}
          <p class="jt-voice__meter {{if this.isRecording '--recording'}}">
            <span aria-hidden="true" class="jt-voice__dot"></span>
            <span class="jt-voice__clock">{{this.elapsed}}</span>
            <span class="jt-voice__limit">/ {{this.limit}}</span>
          </p>
        {{/if}}
      </:body>
      <:footer>
        {{#if this.isIdle}}
          <DButton
            class="btn-primary jt-voice__record"
            @action={{this.record}}
            @icon="microphone"
            @label={{themePrefix "jt.voice.record"}}
          />
        {{else if this.isRecording}}
          <DButton
            class="btn-danger jt-voice__stop"
            @action={{this.stop}}
            @icon="stop"
            @label={{themePrefix "jt.voice.stop"}}
          />
        {{else}}
          <DButton
            class="btn-primary jt-voice__add"
            @action={{this.add}}
            @icon="plus"
            @label={{themePrefix "jt.voice.add"}}
          />
          <DButton
            class="btn-default jt-voice__again"
            @action={{this.again}}
            @icon="rotate"
            @label={{themePrefix "jt.voice.again"}}
          />
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
