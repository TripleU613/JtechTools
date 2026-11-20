import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import JtechReactionLevelsGrid from "../../../components/jtech-reaction-levels-grid.gts";

const JtechToolsReactionLevels: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <div class="jtech-rl-page">
    <AdminAreaSettings
      @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
      @categories={{array "jtech_reaction_levels"}}
      @filter={{@controller.filter}}
      @path="/admin/plugins/jtech-tools/reaction-levels"
      @showBreadcrumb={{false}}
    />
    <JtechReactionLevelsGrid />
  </div>
</template>;

export default JtechToolsReactionLevels;
