import type { TemplateOnlyComponent } from "@ember/component/template-only";
import ReqpmUserButton, {
  type ReqpmButtonUser,
} from "../../components/reqpm-user-button.gts";

const ReqpmButton: TemplateOnlyComponent<{
  Args: { outletArgs: { user: ReqpmButtonUser; close?: () => void } };
}> = <template>
  <ReqpmUserButton @close={{@outletArgs.close}} @user={{@outletArgs.user}} />
</template>;

export default ReqpmButton;
