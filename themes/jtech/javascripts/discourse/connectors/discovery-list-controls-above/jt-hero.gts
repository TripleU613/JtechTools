import type { TemplateOnlyComponent } from "@ember/component/template-only";
import JtHero, { type JtHeroSignature } from "../../components/jt-hero.gts";

interface JtHeroConnectorSignature {
  Args: { outletArgs: JtHeroSignature["Args"] };
}

const JtHeroConnector: TemplateOnlyComponent<JtHeroConnectorSignature> =
  <template>
    <JtHero @category={{@outletArgs.category}} @tag={{@outletArgs.tag}} />
  </template>;

export default JtHeroConnector;
