import type { TemplateOnlyComponent } from "@ember/component/template-only";
import JtGate, { type GateTopic } from "../../components/jt-gate.gts";

interface JtGateConnectorSignature {
  Args: { outletArgs: { model: GateTopic } };
}

// After the post stream, so the gate sits where the clipped post fades out.
const JtGateConnector: TemplateOnlyComponent<JtGateConnectorSignature> =
  <template><JtGate @topic={{@outletArgs.model}} /></template>;

export default JtGateConnector;
