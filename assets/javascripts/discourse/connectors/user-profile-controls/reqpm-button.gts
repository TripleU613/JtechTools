import type { TemplateOnlyComponent } from "@ember/component/template-only";
import ReqpmUserButton, {
  type ReqpmButtonUser,
} from "../../components/reqpm-user-button.gts";

const ReqpmButton: TemplateOnlyComponent<{
  Args: { outletArgs: { model: ReqpmButtonUser } };
}> = <template><ReqpmUserButton @user={{@outletArgs.model}} /></template>;

export default ReqpmButton;
