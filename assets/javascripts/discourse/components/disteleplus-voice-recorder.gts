import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { or } from "truth-helpers";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import {
  applyPeaks,
  buildTrack,
  formatTime,
  normalisePeaks,
  paintBars,
  type WebkitAudioWindow,
} from "../lib/disteleplus-voice-player.ts";
import DisteleplusService, {
  DisteleplusSiteSettings,
  RawMessage,
} from "../services/disteleplus.ts";

interface DisteleplusVoiceRecorderSignature {
  Args: {
    onClose?: () => void;
    onSent?: (message: RawMessage) => void;
  };
}

interface CandidateType {
  mime: string;
  ext: string;
}

type RecorderState =
  | "idle"
  | "requesting"
  | "recording"
  | "preview"
  | "uploading"
  | "error";

// The /uploads.json fields the recorder reads.
interface UploadResponse {
  id?: number;
  errors?: string[];
}

// Inline voice-note recorder that takes the place of the composer bar
// (Telegram-style): recording starts as soon as it appears, a live waveform
// scrolls beside a red dot and timer, stop turns it into a playable preview
// with scrubbing, and send uploads the blob through core's /uploads.json and
// posts a message carrying only that upload. The preview waveform is built
// from the levels captured WHILE recording, so it is the real shape of what
// was said and matches the bubble that lands in the conversation.
//
// Codec choice, in order: OGG/OPUS (Firefox; what Telegram natively speaks),
// WebM/OPUS (Chromium; transcoded server-side for Telegram when ffmpeg is
// available), MP4/AAC (Safari). The file is always named
// `voice-note-<stamp>.<ext>` — that prefix is how the server and the player
// recognise a voice note (see lib/discourse_disteleplus/voice_notes.rb).
const CANDIDATE_TYPES: CandidateType[] = [
  { mime: "audio/ogg;codecs=opus", ext: "ogg" },
  { mime: "audio/webm;codecs=opus", ext: "webm" },
  { mime: "audio/webm", ext: "webm" },
  { mime: "audio/mp4", ext: "m4a" },
];

const LIVE_BARS = 48;
const PREVIEW_BARS = 40;
const LEVEL_FLOOR = 0.06;

function pickType(): CandidateType | null | undefined {
  if (!window.MediaRecorder?.isTypeSupported) {
    return null;
  }
  return CANDIDATE_TYPES.find((c) => MediaRecorder.isTypeSupported(c.mime));
}

function stamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
    `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}

// Downsamples the recorded level history to a fixed bar count (peak per bin).
function historyToPeaks(history: number[], barCount: number): number[] {
  if (!history.length) {
    return new Array<number>(barCount).fill(0.2);
  }
  const bin = history.length / barCount;
  const peaks: number[] = [];
  for (let i = 0; i < barCount; i++) {
    const start = Math.floor(i * bin);
    const end = Math.max(start + 1, Math.floor((i + 1) * bin));
    let peak = 0;
    for (let j = start; j < end && j < history.length; j++) {
      peak = Math.max(peak, history[j]);
    }
    peaks.push(peak);
  }
  return normalisePeaks(peaks);
}

export default class DisteleplusVoiceRecorder extends Component<DisteleplusVoiceRecorderSignature> {
  @service declare siteSettings: DisteleplusSiteSettings;
  @service declare disteleplus: DisteleplusService;

  // idle | requesting | recording | preview | uploading | error
  @tracked state: RecorderState = "idle";
  @tracked elapsed = 0;
  @tracked errorKey: string | null = null;
  @tracked previewPlaying = false;
  @tracked previewPosition = 0;
  @tracked paused = false;
  @tracked caption = "";

  stream: MediaStream | null = null;
  recorder: MediaRecorder | null = null;
  chunks: Blob[] = [];
  blob: Blob | null = null;
  previewUrl: string | null = null;
  previewAudio: HTMLAudioElement | null = null;
  previewBars: HTMLSpanElement[] | null = null;
  type: CandidateType | null = null;
  timer: ReturnType<typeof setInterval> | null = null;
  startedAt = 0;
  analyser: AnalyserNode | null = null;
  audioCtx: AudioContext | null = null;
  meterFrame: number | null = null;
  levelHistory: number[] = [];
  liveBars: HTMLSpanElement[] = [];
  liveIndex = 0;

  declare resumeMeter: (() => void) | undefined;

  willDestroy() {
    super.willDestroy();
    this.teardown();
    this.teardownPreview();
  }

  get maxSeconds(): number {
    return this.siteSettings.disteleplus_voice_note_max_seconds || 300;
  }

  get supported(): boolean {
    return (
      !!navigator.mediaDevices?.getUserMedia &&
      !!window.MediaRecorder &&
      !!pickType()
    );
  }

  get isIdle() {
    return this.state === "idle";
  }

  get isRequesting() {
    return this.state === "requesting";
  }

  get isRecording() {
    return this.state === "recording";
  }

  get isPreview() {
    return this.state === "preview";
  }

  get isUploading() {
    return this.state === "uploading";
  }

  get isError() {
    return this.state === "error";
  }

  get elapsedLabel(): string {
    return formatTime(this.elapsed);
  }

  get maxLabel(): string {
    return formatTime(this.maxSeconds);
  }

  get previewPositionLabel(): string {
    return formatTime(this.previewPosition);
  }

  get progressRatio(): number {
    return Math.min(1, this.elapsed / this.maxSeconds);
  }

  // Conic ring around the record button, filling as the limit approaches.
  get ringStyle(): string {
    return `--ring: ${Math.round(this.progressRatio * 360)}deg`;
  }

  get nearLimit(): boolean {
    return this.isRecording && this.maxSeconds - this.elapsed <= 10;
  }

  get title(): string {
    return i18n("disteleplus.voice.title");
  }

  get errorMessage(): string {
    return this.errorKey ? i18n(this.errorKey) : "";
  }

  get recordButtonLabel(): string {
    return this.isRecording
      ? i18n("disteleplus.voice.stop")
      : i18n("disteleplus.voice.start");
  }

  get previewToggleLabel(): string {
    return this.previewPlaying
      ? i18n("disteleplus.player.pause")
      : i18n("disteleplus.player.play");
  }

  teardown(): void {
    clearInterval(this.timer);
    this.timer = null;
    if (this.meterFrame) {
      cancelAnimationFrame(this.meterFrame);
      this.meterFrame = null;
    }
    if (this.recorder && this.recorder.state !== "inactive") {
      try {
        this.recorder.stop();
      } catch {
        // Already stopping.
      }
    }
    this.recorder = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    this.audioCtx?.close?.();
    this.audioCtx = null;
    this.analyser = null;
  }

  teardownPreview(): void {
    if (this.previewAudio) {
      this.previewAudio.pause();
      this.previewAudio.removeAttribute("src");
      this.previewAudio = null;
    }
    if (this.previewUrl) {
      URL.revokeObjectURL(this.previewUrl);
      this.previewUrl = null;
    }
    this.previewBars = null;
    this.previewPlaying = false;
    this.previewPosition = 0;
  }

  fail(key: string): void {
    this.teardown();
    this.errorKey = key;
    this.state = "error";
  }

  @action
  mountLiveWave(element: HTMLElement) {
    element.replaceChildren();
    this.liveBars = [];
    for (let i = 0; i < LIVE_BARS; i++) {
      const bar = document.createElement("span");
      bar.className = "disteleplus-rec__bar";
      bar.style.setProperty("--peak", String(LEVEL_FLOOR));
      element.appendChild(bar);
      this.liveBars.push(bar);
    }
    this.liveIndex = 0;
  }

  @action
  autoStart() {
    if (this.isIdle) {
      this.start();
    }
  }

  @action
  toggleRecording() {
    if (this.isRecording) {
      this.stop();
    } else if (this.isIdle) {
      this.start();
    }
  }

  async start(): Promise<void> {
    if (!this.supported) {
      this.fail("disteleplus.voice.errors.unsupported");
      return;
    }
    this.state = "requesting";
    this.errorKey = null;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
    } catch (e) {
      const denied =
        (e as DOMException | null)?.name === "NotAllowedError" ||
        (e as DOMException | null)?.name === "SecurityError";
      this.fail(
        denied
          ? "disteleplus.voice.errors.denied"
          : "disteleplus.voice.errors.no_microphone"
      );
      return;
    }

    this.type = pickType();
    this.chunks = [];
    this.levelHistory = [];
    try {
      this.recorder = new MediaRecorder(this.stream, {
        mimeType: this.type.mime,
        audioBitsPerSecond: 48000,
      });
    } catch {
      this.fail("disteleplus.voice.errors.unsupported");
      return;
    }

    this.recorder.addEventListener("dataavailable", (event) => {
      if (event.data?.size) {
        this.chunks.push(event.data);
      }
    });
    this.recorder.addEventListener("stop", () => this.finishRecording());
    this.recorder.addEventListener("error", () =>
      this.fail("disteleplus.voice.errors.recording_failed")
    );

    this.startMeter();
    this.recorder.start(250);
    this.startedAt = Date.now();
    this.elapsed = 0;
    this.paused = false;
    this.state = "recording";
    this.startTimer();
  }

  startTimer(): void {
    // startedAt is recalibrated on resume so elapsed survives pauses.
    this.timer = setInterval(() => {
      this.elapsed = (Date.now() - this.startedAt) / 1000;
      if (this.elapsed >= this.maxSeconds) {
        this.stop();
      }
    }, 100);
  }

  @action
  togglePause() {
    if (!this.isRecording || !this.recorder) {
      return;
    }
    if (this.paused) {
      this.recorder.resume();
      this.startedAt = Date.now() - this.elapsed * 1000;
      this.startTimer();
      this.resumeMeter?.();
      this.paused = false;
    } else {
      this.recorder.pause();
      clearInterval(this.timer);
      this.timer = null;
      if (this.meterFrame) {
        cancelAnimationFrame(this.meterFrame);
        this.meterFrame = null;
      }
      this.paused = true;
    }
  }

  startMeter(): void {
    const AudioCtx =
      window.AudioContext ||
      (window as Window & WebkitAudioWindow).webkitAudioContext;
    if (!AudioCtx) {
      return;
    }
    try {
      this.audioCtx = new AudioCtx();
      const source = this.audioCtx.createMediaStreamSource(this.stream);
      this.analyser = this.audioCtx.createAnalyser();
      this.analyser.fftSize = 512;
      this.analyser.smoothingTimeConstant = 0.6;
      source.connect(this.analyser);
      const data = new Uint8Array(this.analyser.fftSize);
      const tick = () => {
        if (!this.analyser) {
          return;
        }
        if (this.paused) {
          return;
        }
        this.analyser.getByteTimeDomainData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) {
          const v = (data[i] - 128) / 128;
          sum += v * v;
        }
        const rms = Math.sqrt(sum / data.length);
        // Speech RMS sits around 0.05–0.3; sqrt + gain lets a normal voice
        // fill most of the stage without clipping on a shout.
        const level = Math.min(1, Math.max(LEVEL_FLOOR, Math.sqrt(rms) * 1.6));
        this.levelHistory.push(level);
        this.paintLive(level);
        this.meterFrame = requestAnimationFrame(tick);
      };
      this.meterFrame = requestAnimationFrame(tick);
      // Pause cancels the frame loop; resume re-arms it here.
      this.resumeMeter = () => {
        this.meterFrame = requestAnimationFrame(tick);
      };
    } catch {
      // Meter is decoration; recording proceeds without it.
    }
  }

  // Scrolling oscilloscope: newest level enters on the right, the rest
  // slides one slot left.
  paintLive(level: number): void {
    if (!this.liveBars.length) {
      return;
    }
    if (this.liveIndex < this.liveBars.length) {
      this.liveBars[this.liveIndex].style.setProperty(
        "--peak",
        level.toFixed(3)
      );
      this.liveIndex++;
      return;
    }
    for (let i = 0; i < this.liveBars.length - 1; i++) {
      this.liveBars[i].style.setProperty(
        "--peak",
        this.liveBars[i + 1].style.getPropertyValue("--peak")
      );
    }
    this.liveBars[this.liveBars.length - 1].style.setProperty(
      "--peak",
      level.toFixed(3)
    );
  }

  @action
  stop() {
    clearInterval(this.timer);
    this.timer = null;
    if (this.meterFrame) {
      cancelAnimationFrame(this.meterFrame);
      this.meterFrame = null;
    }
    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.stop();
    }
  }

  finishRecording(): void {
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    this.audioCtx?.close?.();
    this.audioCtx = null;
    this.analyser = null;

    if (!this.chunks.length || this.elapsed < 0.5) {
      this.fail("disteleplus.voice.errors.too_short");
      return;
    }
    this.blob = new Blob(this.chunks, { type: this.type.mime.split(";")[0] });
    this.previewUrl = URL.createObjectURL(this.blob);
    this.previewAudio = new Audio(this.previewUrl);
    this.previewAudio.preload = "auto";
    this.previewAudio.addEventListener("timeupdate", () => {
      this.previewPosition = this.previewAudio.currentTime;
      this.paintPreview();
    });
    this.previewAudio.addEventListener("play", () => {
      this.previewPlaying = true;
    });
    this.previewAudio.addEventListener("pause", () => {
      this.previewPlaying = false;
    });
    this.previewAudio.addEventListener("ended", () => {
      this.previewPlaying = false;
      this.previewAudio.currentTime = 0;
      this.previewPosition = 0;
      this.paintPreview();
    });
    // Anything already typed in the composer becomes the caption draft.
    this.caption = this.disteleplus.draft || "";
    this.state = "preview";
  }

  @action
  updateCaption(event: Event) {
    this.caption = (event.target as HTMLInputElement).value;
  }

  @action
  mountPreviewWave(element: HTMLElement) {
    const { track, bars } = buildTrack(PREVIEW_BARS);
    track.setAttribute("aria-label", i18n("disteleplus.player.seek"));
    this.previewBars = bars;
    applyPeaks(bars, historyToPeaks(this.levelHistory, PREVIEW_BARS));
    element.replaceChildren(track);

    const seekTo = (event: PointerEvent) => {
      const rect = track.getBoundingClientRect();
      if (!rect.width || !this.previewAudio) {
        return;
      }
      const ratio = Math.min(
        1,
        Math.max(0, (event.clientX - rect.left) / rect.width)
      );
      const duration = this.previewDuration();
      this.previewAudio.currentTime = ratio * duration;
      this.previewPosition = ratio * duration;
      this.paintPreview();
    };
    let scrubbing = false;
    track.addEventListener("pointerdown", (event) => {
      // Left button only; a right-click belongs to the browser, not the scrub.
      if (event.button !== 0) {
        return;
      }
      event.preventDefault();
      scrubbing = true;
      track.setPointerCapture?.(event.pointerId);
      seekTo(event);
    });
    track.addEventListener("pointermove", (event) => {
      if (scrubbing) {
        seekTo(event);
      }
    });
    const done = () => {
      scrubbing = false;
    };
    track.addEventListener("pointerup", done);
    track.addEventListener("pointercancel", done);
    this.paintPreview();
  }

  previewDuration(): number {
    const d = this.previewAudio?.duration;
    return Number.isFinite(d) && d > 0 ? d : this.elapsed;
  }

  paintPreview(): void {
    if (!this.previewBars) {
      return;
    }
    const duration = this.previewDuration();
    paintBars(this.previewBars, duration ? this.previewPosition / duration : 0);
  }

  @action
  togglePreview() {
    if (!this.previewAudio) {
      return;
    }
    if (this.previewAudio.paused) {
      this.previewAudio.play()?.catch?.(() => {});
    } else {
      this.previewAudio.pause();
    }
  }

  @action
  discard() {
    this.teardown();
    this.teardownPreview();
    this.blob = null;
    this.chunks = [];
    this.levelHistory = [];
    this.elapsed = 0;
    this.errorKey = null;
    this.state = "idle";
    this.args.onClose?.();
  }

  // Stop while recording, send once previewing — one primary button.
  @action
  primary() {
    if (this.isRecording) {
      this.stop();
    } else if (this.isPreview) {
      this.send();
    }
  }

  @action
  async send() {
    if (!this.blob) {
      return;
    }
    this.previewAudio?.pause();
    this.state = "uploading";
    const filename = `voice-note-${stamp()}.${this.type.ext}`;
    const form = new FormData();
    form.append("type", "composer");
    form.append("file", this.blob, filename);

    try {
      const upload: UploadResponse | null = await ajax("/uploads.json", {
        type: "POST",
        data: form,
        processData: false,
        contentType: false,
      });
      if (!upload?.id) {
        throw new Error(upload?.errors?.join(", ") || "upload failed");
      }

      const payload = { raw: this.caption.trim(), upload_ids: [upload.id] };
      const response: { message: RawMessage } = await ajax(
        "/jtech-disteleplus/messages",
        {
          type: "POST",
          data: payload,
        }
      );
      // The caption consumed whatever the composer draft held.
      this.disteleplus.setDraft("");
      this.teardownPreview();
      this.args.onSent?.(response.message);
    } catch (e) {
      this.state = "preview";
      popupAjaxError(e);
    }
  }

  <template>
    <div
      class="disteleplus-vrec
        {{if this.isRecording 'is-recording'}}
        {{if this.nearLimit 'is-near-limit'}}
        {{if this.isPreview 'is-preview'}}
        {{if this.isUploading 'is-uploading'}}
        {{if this.isError 'is-error'}}"
      {{didInsert this.autoStart}}
    >
      <button
        aria-label={{i18n "disteleplus.cancel"}}
        class="disteleplus-vrec__cancel"
        disabled={{this.isUploading}}
        title={{i18n "disteleplus.cancel"}}
        type="button"
        {{on "click" this.discard}}
      >{{icon "trash-can"}}</button>

      {{#if this.isError}}
        <span class="disteleplus-vrec__error">{{icon "microphone-slash"}}
          {{this.errorMessage}}</span>
      {{else if this.isRequesting}}
        <span class="disteleplus-vrec__requesting">{{icon "microphone"}}
          {{i18n "disteleplus.voice.requesting"}}</span>
      {{else if this.isPreview}}
        <button
          aria-label={{this.previewToggleLabel}}
          class="disteleplus-vrec__play"
          type="button"
          {{on "click" this.togglePreview}}
        >{{icon (if this.previewPlaying "pause" "play")}}</button>
        <div
          class="disteleplus-vrec__wave is-preview"
          {{didInsert this.mountPreviewWave}}
        ></div>
        <span class="disteleplus-vrec__time">
          {{this.previewPositionLabel}}
          /
          {{this.elapsedLabel}}</span>
        <input
          class="disteleplus-vrec__caption"
          maxlength="2000"
          placeholder={{i18n "disteleplus.voice.caption_placeholder"}}
          type="text"
          value={{this.caption}}
          {{on "input" this.updateCaption}}
        />
      {{else}}
        <span
          class="disteleplus-vrec__dot {{if this.paused 'is-paused'}}"
        ></span>
        <span class="disteleplus-vrec__time">{{this.elapsedLabel}}</span>
        <div
          class="disteleplus-vrec__wave"
          {{didInsert this.mountLiveWave}}
        ></div>
        <button
          aria-label={{if
            this.paused
            (i18n "disteleplus.voice.resume")
            (i18n "disteleplus.voice.pause")
          }}
          class="disteleplus-vrec__pause"
          title={{if
            this.paused
            (i18n "disteleplus.voice.resume")
            (i18n "disteleplus.voice.pause")
          }}
          type="button"
          {{on "click" this.togglePause}}
        >{{icon (if this.paused "play" "pause")}}</button>
      {{/if}}

      {{#unless this.isError}}
        <button
          aria-label={{if
            this.isRecording
            (i18n "disteleplus.voice.stop")
            (i18n "disteleplus.send")
          }}
          class="disteleplus-vrec__primary
            {{if this.isRecording 'is-stop' 'is-send'}}"
          disabled={{or this.isRequesting this.isUploading}}
          title={{if
            this.isRecording
            (i18n "disteleplus.voice.stop")
            (i18n "disteleplus.send")
          }}
          type="button"
          {{on "click" this.primary}}
        >
          {{#if this.isUploading}}
            {{icon "spinner" class="fa-spin"}}
          {{else if this.isRecording}}
            {{icon "stop"}}
          {{else}}
            {{icon "paper-plane"}}
          {{/if}}
        </button>
      {{/unless}}
    </div>
  </template>
}
