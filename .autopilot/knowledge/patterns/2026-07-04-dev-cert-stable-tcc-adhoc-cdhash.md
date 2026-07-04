# 开发 TCC-gated 功能：自签 cert 让 dev bundle 稳定签名（绕开 ad-hoc cdhash 每次重打包 TCC 失效）

<!-- tags: tcc, code-signing, adhoc, cdhash, self-signed-cert, dev-experience, screen-recording, accessibility, keychain, openssl, pkcs12 -->

**Scenario**: 开发涉及 TCC 权限（屏幕录制 / 辅助功能 / 麦克风 等）的功能，本地 dev 构建（`make bundle` 等）调试。每次改代码重打包都要重新 grant TCC，迭代极慢。

**Lesson**: ad-hoc 签名（`codesign --sign -`）的 TCC 授权绑 **cdhash**（每次重打包二进制变 → cdhash 变 → TCC 失效）。解法：创建一个稳定的自签 code-signing cert，dev bundle 改用它签名 → TCC 绑 cert 身份（designated requirement = cert CN），跨重打包持久 —— grant 一次后续所有 rebuild 保持授权。**cert 必须含 `keyUsage=critical,digitalSignature` + `extendedKeyUsage=codeSigning`**（只加 EKU 不加 keyUsage，macOS codesign 报 "Invalid Key Usage for policy" 拒签）。openssl 3.x 生成的 PKCS12 import 到 macOS keychain 需 `-legacy` + 非空密码（3.x 默认 AES-256-CBC + SHA256 MAC 格式 macOS `security import` 读不了，报 "MAC verification failed"）。cert 还需 trust（`security add-trusted-cert -p codeSign`，会弹 GUI 授权框，必须交互终端跑）。验证标志：`codesign -d -r-` 的 designated requirement 从 `cdhash H"..."` 变 `certificate root = H"..."`（cert root hash 跨重打包稳定）。

**Evidence**: apps/desktop/Scripts/setup-dev-signing.sh（生成 cert claude-code-buddy-dev）+ sign-bundle.sh（bundle.sh/dev-bundle.sh 共用）；`security find-identity -v -p codesigning` 列出该 cert 为 valid；真机验证：同 cert 连续多次 `make bundle` 重打包后触发截屏，buddy 日志全 `perform → overlay present` 直通（无 denied/重授权）。（核对锚点：2026-07-04 源码版本）

**关联**: ad-hoc cdhash churn 是 macOS 本地 dev TCC 功能的通用痛点，此 cert 模式可复用于任何 TCC-gated 功能开发；与 [[2026-07-04-spm-consume-xcodegen-monorepo-umbrella-fork]] 同属工程效率基建。
