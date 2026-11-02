import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";

const JtechToolsMod: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array
      "jtech_mod"
      "jtech_mod_topic_tools"
      "jtech_mod_users"
      "jtech_mod_checklists"
      "jtech_mod_notes"
      "jtech_mod_notifications"
      "jtech_mod_whispers"
    }}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/mod"
    @showBreadcrumb={{false}}
  />
</template>;

export default JtechToolsMod;
