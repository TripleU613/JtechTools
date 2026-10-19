import type { TemplateOnlyComponent } from "@ember/component/template-only";
import RouteTemplate from "ember-route-template";
import ModElectionsPage from "../components/mod-elections-page.gts";
import type ModElectionsController from "../controllers/mod-elections.ts";

const ModElectionsTemplate: TemplateOnlyComponent<{
  Args: { controller: ModElectionsController };
}> = <template><ModElectionsPage @electionId={{@controller.id}} /></template>;

export default RouteTemplate(ModElectionsTemplate);
