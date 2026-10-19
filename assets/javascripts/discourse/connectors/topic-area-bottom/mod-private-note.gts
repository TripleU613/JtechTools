import type { TemplateOnlyComponent } from "@ember/component/template-only";
import ModPrivateNote, {
  type PrivateNoteTopic,
} from "../../components/mod-private-note.gts";

interface ModPrivateNoteConnectorSignature {
  Args: { outletArgs: { model: PrivateNoteTopic } };
}

// Staff-only moderator note, shown at the bottom of the topic when the
// moderator chose the "bottom" placement (the default).
const ModPrivateNoteConnector: TemplateOnlyComponent<ModPrivateNoteConnectorSignature> =
  <template>
    <ModPrivateNote @place="bottom" @topic={{@outletArgs.model}} />
  </template>;

export default ModPrivateNoteConnector;
