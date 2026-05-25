export default {
  "apps/web/**/*.{ts,tsx,js,jsx,mjs,cjs}": [
    "pnpm --filter @stringzhao/web exec eslint --fix",
    "pnpm --filter @stringzhao/web exec prettier --write",
  ],
  "apps/web/**/*.{json,css,md}": [
    "pnpm --filter @stringzhao/web exec prettier --write",
  ],
  // tsc 不能接受文件列表（会绕过 tsconfig.json），用函数形式忽略文件参数
  "packages/skin-cli/**/*.ts": () =>
    "pnpm --filter @stringzhao/skin-cli exec tsc -p tsconfig.json --noEmit",
};
