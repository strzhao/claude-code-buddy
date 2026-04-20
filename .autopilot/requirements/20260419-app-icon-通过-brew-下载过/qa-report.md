# QA 报告

| # | 测试 | 结果 | 证据 |
|---|------|------|------|
| T1 | bundle.sh 产出含 AppIcon.icns | PASS | 41263 bytes |
| T2 | bundle.sh icon 缺失时失败 | PASS | exit code: 1 |
| T3 | release.yml 含完整性验证 | PASS | grep 匹配 |
| T4 | icon 文件类型正确 | PASS | "Mac OS X icon" |
| S1 | CFBundleIconFile 匹配 | PASS | "AppIcon" |
| S2 | YAML 格式正确 | PASS | 无 tab |
| S3 | SwiftLint | PASS | 0 violations |
