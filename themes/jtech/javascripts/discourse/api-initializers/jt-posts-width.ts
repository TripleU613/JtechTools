import { schedule } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";

// On a topic the composer (jt-panels.scss) ends where the posts do. The posts'
// column is what the timeline leaves (or a component's split, like DiscoTOC's
// 75/25), which CSS can't read from the composer, so this keeps its width in
// --jt-posts-width on <html>, and drops it on pages without one.
export default apiInitializer((api) => {
  const root = document.documentElement;
  let observed: Element | null = null;
  let shown = 0;

  // The column also resizes as posts load (its height), and a write on
  // <html> restyles the whole page: only a new width is written.
  const observer = new ResizeObserver(([entry]) => {
    const width = Math.floor(entry.borderBoxSize[0].inlineSize);
    if (width === shown) {
      return;
    }
    shown = width;
    // a column that has just left the page reports 0: never size the
    // composer from that
    if (width > 0) {
      root.style.setProperty("--jt-posts-width", `${width}px`);
    } else {
      root.style.removeProperty("--jt-posts-width");
    }
  });

  api.onPageChange(() => {
    schedule("afterRender", () => {
      const posts = document.querySelector(".container.posts > .row");
      if (posts === observed) {
        return;
      }
      if (observed) {
        observer.unobserve(observed);
      }
      observed = posts;
      if (posts) {
        observer.observe(posts);
      } else {
        shown = 0;
        root.style.removeProperty("--jt-posts-width");
      }
    });
  });
});
