import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import JtechAdminActions, {
  type AdminAction,
} from "../../../components/jtech-admin-actions.gts";

// Maintenance actions rendered as real buttons (the legacy flip-a-checkbox
// *_now settings are hidden; their hooks remain for API callers).
const ACTIONS: AdminAction[] = [
  { id: "register_webhook", icon: "rotate", confirm: true },
  { id: "send_test_message", icon: "paper-plane" },
  { id: "sync_notifications", icon: "bell" },
  { id: "measure_forum_uploads", icon: "chart-bar", confirm: true },
  { id: "backfill_forum_uploads", icon: "upload", confirm: true },
];

const JtechToolsDisteleplus: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array "jtech_disteleplus"}}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/disteleplus"
    @showBreadcrumb={{false}}
  />
  <JtechAdminActions @actions={{ACTIONS}} />
</template>;

export default JtechToolsDisteleplus;
