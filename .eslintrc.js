module.exports = {
  env: {
    browser: false,
    es2021: true,
    mocha: true,
    node: true,
    jest: true,
  },
  extends: ["eslint:recommended", "prettier"],
  parser: "@typescript-eslint/parser",
  plugins: ["@typescript-eslint"],
  parserOptions: {
    ecmaVersion: 12,
    sourceType: "module",
  },
  rules: {
    "prefer-const": "error",
    "no-var": "error",
    "no-unused-vars": "off",
    "@typescript-eslint/no-unused-vars": "error",
  },
  ignorePatterns: [
    "dist/",
    "node_modules/",
    "artifacts/",
    "cache/",
    "frontend/",
    "*.js",
  ],
};
