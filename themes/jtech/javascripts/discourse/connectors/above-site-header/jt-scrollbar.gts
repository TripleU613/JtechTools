import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import JtScrollbar from "../../components/jt-scrollbar.gts";

interface ScrollbarSignature {
  Args: { outletArgs: Record<string, unknown> };
}

const Scrollbar: TemplateOnlyComponent<ScrollbarSignature> = <template>
  {{#if settings.overlay_scrollbar}}
    <JtScrollbar />
  {{/if}}
</template>;

export default Scrollbar;
