import DiscourseRecommended from "@discourse/lint-configs/eslint";
import type { Linter } from "eslint";

const config: Linter.Config[] = [
  ...DiscourseRecommended,
  {
    // These rules rewrite runtime import paths to modules that only exist in
    // the newest cores (discourse/ui-kit/*, discourse/truth-helpers,
    // trustHTML, bare route templates). The plugin still supports older
    // cores (.discourse-compatibility), where the old paths are the only
    // ones; types for them live in types/discourse-shims.d.ts.
    rules: {
      "discourse/ui-kit-imports": "off",
      "discourse/moved-packages-import-paths": "off",
      "discourse/deprecated-imports": "off",
      "discourse/no-route-template": "off",
      // Ember's built-in eq/and/gt… keywords: newest cores only, and Glint
      // (pnpm lint:types) doesn't know them, so it can't check templates
      // that use them
      "discourse/truth-helpers-keywords": "off",
    },
  },
];

export default config;
