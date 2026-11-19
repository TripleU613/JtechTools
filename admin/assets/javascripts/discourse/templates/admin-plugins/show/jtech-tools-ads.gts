import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { array } from "@ember/helper";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import type AdminAreaSettingsBaseController from "discourse/admin/controllers/admin-area-settings-base";
import JtechLinesPreview from "../../../components/jtech-lines-preview.gts";

const JtechToolsAds: TemplateOnlyComponent<{
  Args: { controller: AdminAreaSettingsBaseController };
}> = <template>
  <JtechLinesPreview />
  <AdminAreaSettings
    @adminSettingsFilterChangedCallback={{@controller.adminSettingsFilterChangedCallback}}
    @categories={{array "jtech_ads"}}
    @filter={{@controller.filter}}
    @path="/admin/plugins/jtech-tools/ads"
    @showBreadcrumb={{false}}
  />
</template>;

export default JtechToolsAds;
