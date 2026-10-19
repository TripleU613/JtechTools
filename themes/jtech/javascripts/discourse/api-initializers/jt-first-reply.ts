import { apiInitializer } from "discourse/lib/api";
import JtFirstReply from "../components/jt-first-reply.gts";

export default apiInitializer((api) => {
  api.renderAfterWrapperOutlet("post-article", JtFirstReply);
});
