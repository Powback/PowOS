// The complexity lint (shell/dev/lint-complexity.sh runs it; the gate and tier-1 call that). Only size/complexity
// rules - style is dev/lint-style.sh, types are tsc. Limits are strict on purpose: a function over them is split.
// Existing violations are frozen in eslint-suppressions.json (per file and rule): new code can't add any, and an entry
// that is no longer needed fails the run until pruned (dev/lint-complexity.sh --prune) - the baseline only shrinks.
import tseslint from "typescript-eslint";
import sonarjs from "eslint-plugin-sonarjs";

export const LIMITS = { complexity: 10, cognitive: 10, depth: 3, lines: 60, params: 4 };

export default [
  { ignores: ["node_modules/**", "vendor/**", "**/*.d.ts", "**/out/**", "**/bindings/**", "dev/preview/**", "**/mujoco/**"] },
  {
    files: ["**/*.{ts,tsx,mjs,js}"],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: { ecmaVersion: "latest", sourceType: "module", ecmaFeatures: { jsx: true } },
    },
    linterOptions: { reportUnusedDisableDirectives: "error" },
    plugins: { sonarjs },
    rules: {
      complexity: ["error", { max: LIMITS.complexity }],
      "sonarjs/cognitive-complexity": ["error", LIMITS.cognitive],
      "max-depth": ["error", LIMITS.depth],
      "max-lines-per-function": ["error", { max: LIMITS.lines, skipBlankLines: true, skipComments: true, IIFEs: true }],
      "max-params": ["error", LIMITS.params],
    },
  },
];
