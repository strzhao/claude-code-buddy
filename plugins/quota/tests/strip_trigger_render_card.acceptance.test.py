# -*- coding: utf-8 -*-
"""gcli 改名 + card 通道红队验收：strip_trigger 六例（s2p6）+ render_card clamp（s7p2）。

运行方式（独立可单跑，不被 `unittest discover`（默认 pattern test*.py）拾取）：
    /usr/bin/python3 plugins/quota/tests/strip_trigger_render_card.acceptance.test.py
    /usr/bin/python3 ... strip_trigger_render_card.acceptance.test.py GcliStripTriggerAcceptance   # 只跑 s2p6
    /usr/bin/python3 ... strip_trigger_render_card.acceptance.test.py GcliRenderCardClampAcceptance # 只跑 s7p2

谓词映射（SSOT: state.md ## 验收场景）：
    s2p6 [real-process] Python unittest（strip_trigger 同六例：gc→"" / gcli→"" /
          "gcli kimi"→"kimi" / 限→"" / kim→"kim" / ""→""）exit==0 ｜ artifact: s2p6.out
    s7p2 [real-process] 插件 render_card clamp：fixture percent=120 / percent=-5
          → card 文件对应值 == 100 / 0 ｜ artifact: s7p2.out

红队信息隔离声明：仅依赖 state.md ## 契约规约 声明的接口名
（TRIGGER_WORDS / strip_trigger(query) -> str / render_card(report) -> dict）与
card JSON schema；report dict 形状沿用既有纯函数测试约定（tests/test_parsers.py
的 make_result：display_name/names/is_current/kind/windows/error）——设计未重复
声明该形状，CONTRACT_AMBIGUOUS 已注记。未读取蓝队新写实现。
"""

import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone

# 插件目录定位：target 布局（plugins/quota/tests/ 本文件 → 上两级）；
# staging 平铺布局经 QUOTA_DIR env 显式指路。定位失败 = import error = 红灯（非软跳过）。
QUOTA_DIR = os.environ.get("QUOTA_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
if QUOTA_DIR not in sys.path:
    sys.path.insert(0, QUOTA_DIR)

import quota  # noqa: E402

ART_DIR = "/tmp/autopilot-artifacts"

_ANCHOR = datetime(2026, 9, 20, 12, 0, 0, tzinfo=timezone.utc)
NOW_MS = int(_ANCHOR.timestamp() * 1000)


def iso_at(offset_minutes):
    """相对锚点偏移 N 分钟的 ISO8601 时间串（test_parsers 同构）。"""
    return quota._to_reset_iso(NOW_MS + offset_minutes * 60000)


def write_artifact(name, lines):
    os.makedirs(ART_DIR, exist_ok=True)
    with open(os.path.join(ART_DIR, name), "w", encoding="utf-8") as f:
        f.write("\n".join([name] + lines) + "\n")


class GcliStripTriggerAcceptance(unittest.TestCase):
    """s2p6：strip_trigger 六例（## 契约规约 逐字）+ TRIGGER_WORDS 词表契约。"""

    def test_s2p6_strip_trigger_six_cases(self):
        # (query, expected) —— 字面量逐字取自 s2p5/s2p6 谓词
        six = [
            ("gc", ""),            # 正例：keyword "gcli" 的非空真前缀（W2 新分支）
            ("gcli", ""),          # 边界：全等触发词（既有）
            ("gcli kimi", "kimi"), # 边界：触发词+空格剥离剩余（既有）
            ("限", ""),             # 正例：中文 keyword "限额" 的前缀（W2 新分支）
            ("kim", "kim"),        # 反例：非任何触发词前缀 → 原样（quota/limit 已移出词表）
            ("", ""),              # 反例：空早返
        ]
        evidence = ["QUOTA_DIR=%s" % QUOTA_DIR]
        for q, want in six:
            got = quota.strip_trigger(q)
            evidence.append("strip_trigger(%r) = %r (expect %r)" % (q, got, want))
            self.assertEqual(got, want,
                             "s2p6: strip_trigger(%r) 期望 %r 实际 %r" % (q, want, got))
        # 契约规约字面量：TRIGGER_WORDS = ("gcli", "限额", "套餐", "用量")
        self.assertEqual(
            tuple(quota.TRIGGER_WORDS), ("gcli", "限额", "套餐", "用量"),
            "s2p6 契约: TRIGGER_WORDS 必须 == ('gcli','限额','套餐','用量')，实际 %r"
            % (quota.TRIGGER_WORDS,))
        evidence.append("TRIGGER_WORDS == ('gcli','限额','套餐','用量')")
        evidence.append("PASS")
        write_artifact("s2p6.out", evidence)


class GcliRenderCardClampAcceptance(unittest.TestCase):
    """s7p2：render_card 产出前 clamp（percent 120→100 / -5→0），card 文件回读校验。"""

    def test_s7p2_render_card_clamp_to_file(self):
        # CONTRACT_AMBIGUOUS：render_card(report) 的 report 形状设计未重复声明，
        # 沿用既有 render_report 输入约定（display_name/names/is_current/kind/windows/error）。
        report = [{
            "display_name": "kimi",
            "names": ["kimi"],
            "is_current": False,
            "kind": "kimi",
            "windows": {"short": (120, iso_at(200)),   # 越上界 → 100
                        "weekly": (-5, iso_at(3000))},  # 越下界 → 0
            "error": False,
        }]
        card = quota.render_card(report)

        # 谓词 observe = card 文件：render_card 产物落盘后回读（镜像插件 main 的写文件路径）
        fd, path = tempfile.mkstemp(suffix=".card.json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(json.dumps(card, ensure_ascii=False))
            with open(path, encoding="utf-8") as f:
                card_on_disk = json.load(f)
        finally:
            os.unlink(path)

        evidence = ["card=%s" % json.dumps(card_on_disk, ensure_ascii=False)]

        # title 契约字面量（设计 card JSON schema 例）：gcli 套餐限额 · N 个
        self.assertEqual(card_on_disk.get("title"), "gcli 套餐限额 · 1 个",
                         "s7p2: card title 必须为 'gcli 套餐限额 · 1 个'（W1 字样+条目数），实际 %r"
                         % card_on_disk.get("title"))
        entries = card_on_disk.get("entries") or []
        self.assertEqual(len(entries), 1, "s7p2: fixture 1 条目")
        entry = entries[0]
        self.assertIn("badge", entry, "s7p2: badge 字段必须存在（可空）")
        windows = entry.get("windows") or []
        by_label = {w.get("label"): w.get("percent") for w in windows}
        self.assertEqual(by_label.get("5h"), 100,
                         "s7p2: percent=120 必须 clamp 到 100，实际 %r" % by_label.get("5h"))
        self.assertEqual(by_label.get("周窗"), 0,
                         "s7p2: percent=-5 必须 clamp 到 0，实际 %r" % by_label.get("周窗"))
        # level 契约：双窗最大 120 → ≥85 → danger
        self.assertEqual(entry.get("level"), "danger",
                         "s7p2: max(120,-5)=120 ≥85 → level danger，实际 %r" % entry.get("level"))

        evidence.append("clamp: 120->%s, -5->%s" % (by_label.get("5h"), by_label.get("周窗")))
        evidence.append("PASS")
        write_artifact("s7p2.out", evidence)


if __name__ == "__main__":
    unittest.main()
