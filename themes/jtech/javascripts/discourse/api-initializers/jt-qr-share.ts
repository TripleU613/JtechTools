import { settings, themePrefix } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import type ModalService from "discourse/services/modal";
import { i18n } from "discourse-i18n";
import JtQr from "../components/modal/jt-qr.gts";

// QR code among the share options (topic and post sharing, the buttons over
// a quote): the link as a code to scan with a phone (setting qr_code_share;
// it replaces the QR Code Shareables component).
export default apiInitializer((api) => {
  if (!settings.qr_code_share) {
    return;
  }
  const modal = api.container.lookup("service:modal") as ModalService;
  api.addSharingSource({
    id: "jt-qr",
    icon: "qrcode",
    title: i18n(themePrefix("jt.qr.share")),
    // a link to a message or a login-only forum only opens for people who
    // could see it anyway
    showInPrivateContext: true,
    clickHandler: (url: string, title: string) =>
      modal.show(JtQr, { model: { url, title } }),
  });
});
