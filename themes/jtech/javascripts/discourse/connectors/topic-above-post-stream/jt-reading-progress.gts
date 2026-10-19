import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import JtReadingProgress from "../../components/jt-reading-progress.gts";

interface JtReadingProgressConnectorSignature {
  Args: { outletArgs: Record<string, unknown> };
}

const JtReadingProgressConnector: TemplateOnlyComponent<JtReadingProgressConnectorSignature> =
  <template>
    {{#if settings.reading_progress}}
      <JtReadingProgress />
    {{/if}}
  </template>;

export default JtReadingProgressConnector;
