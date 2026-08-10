<!-- tags: stop-hook, predicate, artifact, backtick, dup, md5, pred-artifact-missing, pred-artifact-dup, autopilot, qa, format -->
# stop-hook §5.7 谓词 artifact 两个格式坑（反引号 + 复制）

编排器图省事的两个偷懒被 stop-hook §5.7 机械守卫抓住，各 block 一轮（不耗 max_retries 但拖慢循环）。

## 坑 1：artifact 路径不能用 markdown 反引号包裹 → PRED-ARTIFACT-MISSING
`## 验收场景` 里写成 `artifact: \`/tmp/autopilot-artifacts/p1.out\``（反引号包裹，图 markdown 美观）。stop-hook 的 awk（`lib.sh` `validate_predicate_artifacts`）解析 `artifact:[[:space:]]*` 后取到行尾（无全角 ｜ 分隔时），`gsub` **只 strip 空白、不 strip 反引号** → 解析出的路径含反引号字符 → `[ -f "$artifact" ]` 检查带反引号的文件名 → 不存在 → `PRED-ARTIFACT-MISSING`，即使真实文件就在那里（723 字节非空）。

**根因定位关键**：stop-hook 错误信息里打印的 artifact 路径**带反引号**（`` PRED-ARTIFACT-MISSING: P1 `/tmp/.../p1.out` ``）——错误回显本身就是证据，看到路径含包裹字符即定位。

**修法**：artifact 路径写纯路径，无任何包裹。这是 [[2026-07-14-autolayout-chain-collapse]] 里"artifact 路径禁带括号注释"的**同族扩展——禁带一切非路径字符（括号、反引号、引号、markdown 修饰）**。

## 坑 2：多谓词 artifact 不能复制相同内容 → PRED-ARTIFACT-DUP
图省事把一个红队 test 输出 `cp` 成 P1/P2/P3 三个 artifact（Wave 1.5 时 `cp p1 p2 p3`）。三个路径不同但 **MD5 相同** → stop-hook §5.7 (e) `validate_predicate_artifact_uniqueness` 判定"路径不同 + 内容相同 = 复制冒充独立产物" → `PRED-ARTIFACT-DUP`。

**修法**：每条谓词的 artifact 必须是**各自独立的真实驱动输出**——P1 是"Stop+active.ptr→idle"的捕获、P2 是"Stop+无 active.ptr→task_complete"的捕获、P3 是"notify 各场景 sound name"的检查。分别驱动生成，内容天然不同、MD5 天然互异。写一个 `generate-artifacts.py` 逐谓词独立驱动最稳（capture socket / mock osascript 各跑各的）。

## 元教训
stop-hook §5.7 是确定性机械守卫，专抓两类编排器偷懒：① 路径美化（markdown 包裹）；② 内容复制（一个输出冒充 N 个产物）。预注册谓词时——**artifact 路径纯写（裸路径）、每个谓词独立驱动生成独立 artifact**。两个 block 都不耗 max_retries，但各浪费一轮 stop-hook 循环，合起来拖慢 QA 收尾。第一轮就该按规矩来，别图 markdown 美观和省事 cp。
