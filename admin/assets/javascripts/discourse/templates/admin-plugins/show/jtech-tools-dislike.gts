import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import JtechAdminActions, {
  type AdminAction,
} from "../../../components/jtech-admin-actions.gts";

// The purge used to be a self-resetting checkbox setting; it is a button now.
const ACTIONS: AdminAction[] = [
  { id: "purge_phantom_likes", icon: "trash-can", confirm: true },
];

const JtechToolsDislike: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array "jtech_dislike"}}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/dislike"
    @showBreadcrumb={{false}}
  />
  <JtechAdminActions @actions={{ACTIONS}} />
</template>;

export default JtechToolsDislike;
