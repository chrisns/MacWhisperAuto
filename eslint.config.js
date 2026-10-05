export default [
  {
    files: ["Extension/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        // Browser extension globals
        chrome: "readonly",
        browser: "readonly",
        // Web APIs
        console: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        WebSocket: "readonly",
        URL: "readonly",
        MutationObserver: "readonly",
        document: "readonly",
        window: "readonly",
        navigator: "readonly",
        location: "readonly",
        self: "readonly",
        importScripts: "readonly",
        // Shared helpers from Extension/rules.js (loaded as a classic script)
        customRulesKey: "readonly",
        macWhisperSources: "readonly",
        normalizePattern: "readonly",
        patternOrigin: "readonly",
        patternToRegExp: "readonly",
        loadAllCustomRules: "readonly",
        loadCustomRules: "readonly",
        findCustomRule: "readonly",
        customRuleIsActive: "readonly",
      },
    },
    rules: {
      "no-unused-vars": ["warn", { argsIgnorePattern: "^_" }],
      "no-undef": "error",
      "no-constant-condition": "warn",
      "no-debugger": "warn",
      eqeqeq: ["warn", "always"],
      "no-var": "warn",
    },
  },
  {
    // rules.js defines the shared helpers above as top-level functions
    files: ["Extension/rules.js"],
    languageOptions: { sourceType: "script" },
    rules: {
      "no-unused-vars": "off",
      "no-redeclare": "off",
    },
  },
];
