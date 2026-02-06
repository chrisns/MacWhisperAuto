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
];
