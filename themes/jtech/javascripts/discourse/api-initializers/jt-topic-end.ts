import { schedule } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";

// html.jt-topic-end while the buttons under a topic are on screen: there the
// progress capsule steps aside (jt-topic-progress.scss), so the buttons are
// one row instead of the capsule resting on top of them.
export default apiInitializer((api) => {
  const root = document.documentElement;
  let observed: Element | null = null;
  const observer = new IntersectionObserver(([entry]) => {
    root.classList.toggle("jt-topic-end", entry.isIntersecting);
  });

  const watch = () => {
    const footer = document.getElementById("topic-footer-buttons");
    if (footer === observed) {
      return;
    }
    if (observed) {
      observer.unobserve(observed);
    }
    observed = footer;
    if (footer) {
      observer.observe(footer);
    } else {
      root.classList.remove("jt-topic-end");
    }
  };

  // The buttons appear once the topic's last posts have loaded, which can be
  // well after the page changed: look again as the topic scrolls
  api.onPageChange(() => schedule("afterRender", watch));
  api.onAppEvent("topic:current-post-scrolled", watch);
});
