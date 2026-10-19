import RouteTemplate from "ember-route-template";
import hideApplicationFooter from "discourse/helpers/hide-application-footer";
import DisteleplusConversation from "../components/disteleplus-conversation.gts";

// No site footer under the full page: it made the window scroll, so a growing
// composer pushed the page down instead of up into the messages.
export default RouteTemplate(
  <template>
    {{hideApplicationFooter}}
    <DisteleplusConversation />
  </template>
);
