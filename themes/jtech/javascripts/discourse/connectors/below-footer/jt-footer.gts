import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import JtFooter from "../../components/jt-footer.gts";

interface JtFooterConnectorSignature {
  Args: { outletArgs: { showFooter: boolean } };
}

// Core's showFooter already waits for infinite scroll to reach the end.
const JtFooterConnector: TemplateOnlyComponent<JtFooterConnectorSignature> =
  <template>
    {{#if settings.footer_enabled}}
      {{#if @outletArgs.showFooter}}
        <JtFooter />
      {{/if}}
    {{/if}}
  </template>;

export default JtFooterConnector;
