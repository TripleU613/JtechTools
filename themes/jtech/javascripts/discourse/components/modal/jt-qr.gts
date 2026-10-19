import Component from "@glimmer/component";
import { action } from "@ember/object";
import { type TrustedHTML, trustHTML } from "@ember/template";
import type { ComponentLike } from "@glint/template";
import { themePrefix } from "virtual:theme";
import { escapeExpression } from "discourse/lib/utilities";
import DButton from "discourse/ui-kit/d-button";
import DModalBase from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import { qrMatrix } from "../../lib/jt-qr.ts";

const DModal = DModalBase as unknown as ComponentLike<{
  Element: HTMLDivElement | HTMLFormElement;
  Args: { closeModal?: () => void; title?: string };
  Blocks: { body: []; footer: [] };
}>;

interface JtQrSignature {
  Args: { closeModal: () => void; model: { url: string; title?: string } };
}

// Quiet zone around the code, in modules, as the spec asks for.
const QUIET = 4;

// A link as a QR code to scan with a phone (setting qr_code_share), black on
// white in either colour mode, since scanners expect that, and Save for a
// PNG of it.
export default class JtQr extends Component<JtQrSignature> {
  get matrix() {
    return qrMatrix(this.args.model.url);
  }

  get svg(): TrustedHTML {
    const m = this.matrix;
    const size = m.length + QUIET * 2;
    let path = "";
    m.forEach((row, y) =>
      row.forEach((dark, x) => {
        if (dark) {
          path += `M${x + QUIET} ${y + QUIET}h1v1h-1z`;
        }
      })
    );
    return trustHTML(
      `<svg viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges" role="img" aria-label="${escapeExpression(i18n(themePrefix("jt.qr.label")))}"><rect width="100%" height="100%" fill="#fff"/><path d="${path}" fill="#000"/></svg>`
    );
  }

  @action
  save() {
    const m = this.matrix;
    const scale = 10;
    const size = (m.length + QUIET * 2) * scale;
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      return;
    }
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, size, size);
    ctx.fillStyle = "#000";
    m.forEach((row, y) =>
      row.forEach((dark, x) => {
        if (dark) {
          ctx.fillRect((x + QUIET) * scale, (y + QUIET) * scale, scale, scale);
        }
      })
    );
    const link = document.createElement("a");
    link.href = canvas.toDataURL("image/png");
    link.download = "qr-code.png";
    link.click();
  }

  <template>
    <DModal
      class="jt-qr"
      @closeModal={{@closeModal}}
      @title={{i18n (themePrefix "jt.qr.title")}}
    >
      <:body>
        <div class="jt-qr__code">{{this.svg}}</div>
        <p class="jt-qr__url" dir="ltr">{{@model.url}}</p>
      </:body>
      <:footer>
        <DButton
          class="btn-primary jt-qr__save"
          @action={{this.save}}
          @icon="download"
          @label={{themePrefix "jt.qr.save"}}
        />
      </:footer>
    </DModal>
  </template>
}
