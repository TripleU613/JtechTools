import type { TemplateOnlyComponent } from "@ember/component/template-only";
import RouteTemplate from "ember-route-template";
import type User from "discourse/models/user";
import ReqpmPreferences from "../../components/reqpm-preferences.gts";

const PreferencesReqpmTemplate: TemplateOnlyComponent<{
  Args: { controller: { model: User & { id: number } } };
}> = <template>
  <ReqpmPreferences
    @showHeading={{true}}
    @showHubLink={{true}}
    @user={{@controller.model}}
  />
</template>;

export default RouteTemplate(PreferencesReqpmTemplate);
