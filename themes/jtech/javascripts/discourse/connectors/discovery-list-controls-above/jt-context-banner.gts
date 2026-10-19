import type { TemplateOnlyComponent } from "@ember/component/template-only";
import JtContextBanner, {
  type JtContextBannerSignature,
} from "../../components/jt-context-banner.gts";

interface JtContextBannerConnectorSignature {
  Args: { outletArgs: JtContextBannerSignature["Args"] };
}

const JtContextBannerConnector: TemplateOnlyComponent<JtContextBannerConnectorSignature> =
  <template>
    <JtContextBanner
      @category={{@outletArgs.category}}
      @tag={{@outletArgs.tag}}
    />
  </template>;

export default JtContextBannerConnector;
