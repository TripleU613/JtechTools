import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import ModElectionsAdmin from "../../../components/mod-elections-admin.gts";

// The election itself first (what's happening, what needs doing), then the
// settings.
const JtechToolsModElections: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <ModElectionsAdmin />
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array "jtech_mod_elections"}}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/mod-elections"
    @showBreadcrumb={{false}}
  />
</template>;

export default JtechToolsModElections;
