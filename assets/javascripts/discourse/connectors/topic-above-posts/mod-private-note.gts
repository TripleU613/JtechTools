import type { TemplateOnlyComponent } from "@ember/component/template-only";
import ModPrivateNote, {
  type PrivateNoteTopic,
} from "../../components/mod-private-note.gts";

interface ModPrivateNoteConnectorSignature {
  Args: { outletArgs: { model: PrivateNoteTopic } };
}

// Staff-only moderator note, shown above the posts when the moderator
// chose the "top" placement.
const ModPrivateNoteConnector: TemplateOnlyComponent<ModPrivateNoteConnectorSignature> =
  <template>
    <ModPrivateNote @place="top" @topic={{@outletArgs.model}} />
  </template>;

export default ModPrivateNoteConnector;
