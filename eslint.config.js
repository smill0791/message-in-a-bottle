// @ts-check
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";

/**
 * One flat config for both workspaces.
 *
 * Deliberately close to the recommended sets rather than a house style. The
 * value of lint here is catching what survives review and breaks at runtime -
 * a floating promise, an unused variable hiding a typo - not enforcing where
 * the braces go. Formatting arguments in CI are a tax on every commit and
 * teach nothing.
 */
export default tseslint.config(
    {
        // Build output, dependencies, and Terraform. Linting dist/ would
        // report on generated code nobody can act on.
        ignores: [
            "**/dist/**",
            "**/node_modules/**",
            "infra/**",
        ],
    },

    js.configs.recommended,

    {
        /**
         * Type-aware linting, api only.
         *
         * The rules worth having - no-floating-promises above all - need the
         * type checker, not just the syntax tree. That costs a real TypeScript
         * program build on every lint, which is why it is scoped to the server
         * code where an unhandled rejection means a hung request rather than a
         * console warning.
         */
        files: ["api/**/*.ts"],
        extends: [...tseslint.configs.recommendedTypeChecked],
        languageOptions: {
            globals: globals.node,
            parserOptions: {
                // An explicit lint-only project rather than projectService,
                // because the tests live outside api/tsconfig.json by design
                // and allowDefaultProject refuses the glob needed to readmit
                // them. See api/tsconfig.eslint.json.
                project: ["./api/tsconfig.eslint.json"],
                tsconfigRootDir: import.meta.dirname,
            },
        },
        rules: {
            "@typescript-eslint/no-floating-promises": "error",

            /**
             * Off, because Fastify's plugin contract requires it.
             *
             * Every route module is registered as an async plugin - that is
             * the signature Fastify expects - but most only call synchronous
             * `app.get(...)` registrations in their body. The rule is correct
             * that there is no await; it is wrong that the async is
             * redundant. Nine false positives and no true ones.
             */
            "@typescript-eslint/require-await": "off",

            // Underscore prefix is the conventional way to say "required by
            // the signature, deliberately unused".
            "@typescript-eslint/no-unused-vars": [
                "error",
                { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
            ],
        },
    },

    {
        // The frontend gets syntax-level linting only. It has no async
        // lifecycle worth type-checking a promise through, and keeping the
        // type-aware pass off here keeps lint fast.
        files: ["web/**/*.ts", "web/**/*.tsx"],
        extends: [...tseslint.configs.recommended],
        languageOptions: {
            globals: globals.browser,
        },
    },

    {
        files: ["**/*.test.ts"],
        rules: {
            "@typescript-eslint/no-explicit-any": "off",

            /**
             * Off in tests only.
             *
             * `test()` and `describe()` from node:test return promises that
             * the runner owns and awaits itself - not awaiting them is the
             * documented API, not an oversight. Every call site in a test file
             * trips this rule, so leaving it on would mean prefixing the
             * entire suite with `void` and teaching everyone to ignore it.
             *
             * It stays an error in application code, where a floating promise
             * is a hung request.
             */
            "@typescript-eslint/no-floating-promises": "off",
        },
    },

    {
        // This config file itself.
        files: ["eslint.config.js"],
        languageOptions: { globals: globals.node },
    },
);
