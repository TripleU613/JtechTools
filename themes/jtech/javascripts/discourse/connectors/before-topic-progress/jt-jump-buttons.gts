import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import type Topic from "discourse/models/topic";
import JtJumpButtons from "../../components/jt-jump-buttons.gts";

interface JtProgressJumpSignature {
  Args: { outletArgs: { model: Topic } };
}

const JtProgressJump: TemplateOnlyComponent<JtProgressJumpSignature> =
  <template>
    {{#if settings.topic_jump_buttons}}
      <JtJumpButtons @className="--progress" @topic={{@outletArgs.model}} />
    {{/if}}
  </template>;

export default JtProgressJump;
