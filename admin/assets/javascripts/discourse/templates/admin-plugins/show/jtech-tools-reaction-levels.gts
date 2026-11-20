import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import JtechReactionLevelsTable from "../../../components/jtech-reaction-levels-table.gts";

const JtechToolsReactionLevels: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <JtechReactionLevelsTable />
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array "jtech_reaction_levels"}}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/reaction-levels"
    @showBreadcrumb={{false}}
  />
</template>;

export default JtechToolsReactionLevels;
