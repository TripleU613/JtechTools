import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { settings } from "virtual:theme";
import type Topic from "discourse/models/topic";
import JtJumpButtons from "../../components/jt-jump-buttons.gts";

interface JtTimelineJumpSignature {
  Args: { outletArgs: { model: Topic } };
}

const JtTimelineJump: TemplateOnlyComponent<JtTimelineJumpSignature> =
  <template>
    {{#if settings.topic_jump_buttons}}
      <JtJumpButtons @className="--timeline" @topic={{@outletArgs.model}} />
    {{/if}}
  </template>;

export default JtTimelineJump;
