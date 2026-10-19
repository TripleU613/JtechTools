import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import JtBackToTop from "../../components/jt-back-to-top.gts";

interface BackToTopSignature {
  Args: { outletArgs: Record<string, unknown> };
}

const BackToTop: TemplateOnlyComponent<BackToTopSignature> = <template>
  {{#if settings.back_to_top}}
    <JtBackToTop />
  {{/if}}
</template>;

export default BackToTop;
