# -*- coding: utf-8 -*-
"""quota 插件协议纯函数单元测试。

用例语义移植自 gcli（~/workspace/honeydo/packages/gcli/src/）：
- cli.ts:548-820  buildQuotaRequest / parseKimiUsages / parseGlmQuota / formatReset
- quota-color.acceptance.test.ts      （阈值 85/60 边界、双窗独立判定）
- format-quota-purity.acceptance.test.ts（纯文本输出无 ANSI、过期 reset 省略 ↻）

约定：畸形输入一律降级不抛错（缺窗口 ≠ crash）。
"""

import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.dirname(HERE)
if PLUGIN_DIR not in sys.path:
    sys.path.insert(0, PLUGIN_DIR)

import quota  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")

# 时间锚点：2026-09-20T12:00:00Z（与 gcli purity 测试同构的 at() 相对构造法）。
_ANCHOR = datetime(2026, 9, 20, 12, 0, 0, tzinfo=timezone.utc)
NOW_MS = int(_ANCHOR.timestamp() * 1000)


def iso_at(offset_minutes):
    """相对锚点偏移 N 分钟的 ISO8601 时间串（走 _to_reset_iso 的 epoch-ms 路径）。"""
    return quota._to_reset_iso(NOW_MS + offset_minutes * 60000)


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# build_quota_request — C-Q1 域名分类 + 请求构造（Bearer 差异）
# ---------------------------------------------------------------------------

class TestBuildQuotaRequest(unittest.TestCase):
    def test_kimi_domain_bearer(self):
        req = quota.build_quota_request(
            "https://api.kimi.com/coding/", "sk-test-token")
        self.assertEqual(req[0], "kimi")
        self.assertEqual(req[1], "https://api.kimi.com/coding/v1/usages")
        self.assertEqual(req[2], "Bearer sk-test-token")

    def test_moonshot_substring_maps_kimi(self):
        req = quota.build_quota_request(
            "https://api.moonshot.cn/anthropic", "sk-t")
        self.assertEqual(req[0], "kimi")
        self.assertEqual(req[1], "https://api.moonshot.cn/coding/v1/usages")

    def test_bigmodel_maps_glm_bare_token(self):
        req = quota.build_quota_request(
            "https://open.bigmodel.cn/api/anthropic", "tok-xyz")
        self.assertEqual(req[0], "glm")
        self.assertEqual(req[1],
                         "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        # GLM 契约：裸 token，绝无 Bearer 前缀（带前缀会 401）
        self.assertEqual(req[2], "tok-xyz")
        self.assertNotIn("Bearer", req[2])

    def test_zai_domain_maps_glm(self):
        req = quota.build_quota_request("https://z.ai/api/anthropic", "tok")
        self.assertEqual(req[0], "glm")
        self.assertEqual(req[1], "https://z.ai/api/monitor/usage/quota/limit")

    def test_unsupported_domain_null(self):
        for base in ("https://api.deepseek.com/anthropic",
                     "https://slb-v1.api.fan",
                     "https://api.anthropic.com"):
            self.assertIsNone(quota.build_quota_request(base, "tok"))

    def test_missing_or_empty_base_token_null(self):
        self.assertIsNone(quota.build_quota_request(None, "tok"))
        self.assertIsNone(quota.build_quota_request("", "tok"))
        self.assertIsNone(quota.build_quota_request("https://api.kimi.com", None))
        self.assertIsNone(quota.build_quota_request("https://api.kimi.com", ""))
        self.assertIsNone(quota.build_quota_request(123, "tok"))

    def test_non_http_scheme_null(self):
        self.assertIsNone(quota.build_quota_request("ftp://api.kimi.com/x", "tok"))
        self.assertIsNone(quota.build_quota_request("api.kimi.com", "tok"))


# ---------------------------------------------------------------------------
# _to_num / _to_reset_iso — 数值与时间规整（JS 语义对齐）
# ---------------------------------------------------------------------------

class TestToNum(unittest.TestCase):
    def test_numeric_string(self):
        self.assertEqual(quota._to_num("42"), 42.0)
        self.assertEqual(quota._to_num("3.5"), 3.5)

    def test_number_passthrough(self):
        self.assertEqual(quota._to_num(7), 7.0)
        self.assertEqual(quota._to_num(-0.5), -0.5)

    def test_garbage_none(self):
        for bad in ("abc", "", None, [1], {}, True, False):
            self.assertIsNone(quota._to_num(bad), "bool 必须拒（JS typeof 非 number/string）")

    def test_nonfinite_none(self):
        self.assertIsNone(quota._to_num(float("inf")))
        self.assertIsNone(quota._to_num(float("nan")))


class TestToResetIso(unittest.TestCase):
    def test_string_passthrough(self):
        self.assertEqual(quota._to_reset_iso("2026-09-20T18:13:00.000Z"),
                         "2026-09-20T18:13:00.000Z")

    def test_epoch_ms_number_to_iso(self):
        iso = quota._to_reset_iso(1789990380000)
        self.assertTrue(iso.endswith("Z"))
        self.assertIn("T", iso)
        self.assertIn(".000Z", iso)

    def test_invalid_none(self):
        for bad in ("", None, 0, -5, True, [], {}):
            self.assertIsNone(quota._to_reset_iso(bad))

    def test_garbage_string_passthrough_gcli_parity(self):
        # gcli 同款：字符串原样透传，解析失败推迟到 format_reset（→ 省略 ↻）
        self.assertEqual(quota._to_reset_iso("not-a-number"), "not-a-number")


# ---------------------------------------------------------------------------
# parse_kimi_usages — C-Q2 kimi 双窗
# ---------------------------------------------------------------------------

class TestParseKimiUsages(unittest.TestCase):
    def test_real_fixture_short_and_weekly(self):
        wins = quota.parse_kimi_usages(load_fixture("kimi_usages.json"))
        self.assertEqual(wins["short"], (28, "2026-09-20T18:13:00.000Z"))
        self.assertEqual(wins["weekly"], (39, "2026-09-28T00:00:00.000Z"))

    def test_duration_10080_entry_not_short(self):
        # 周窗条目（duration=10080 且 MINUTE）不得混入 5h 短窗
        body = {
            "limits": [
                {"window": {"duration": 10080, "timeUnit": "MINUTE"},
                 "detail": {"used": "1", "limit": "10",
                            "resetTime": "2026-09-27T00:00:00.000Z"}},
                {"window": {"duration": 300, "timeUnit": "MINUTE"},
                 "detail": {"used": "5", "limit": "10",
                            "resetTime": "2026-09-20T18:13:00.000Z"}},
            ]
        }
        wins = quota.parse_kimi_usages(body)
        self.assertEqual(wins["short"], (50, "2026-09-20T18:13:00.000Z"))

    def test_used_missing_uses_limit_minus_remaining(self):
        body = {
            "limits": [
                {"window": {"duration": 300, "timeUnit": "MINUTE"},
                 "detail": {"limit": "200", "remaining": "150",
                            "resetTime": "2026-09-20T18:13:00.000Z"}},
            ]
        }
        wins = quota.parse_kimi_usages(body)
        self.assertEqual(wins["short"][0], 25)

    def test_malformed_fixture_all_windows_dropped(self):
        wins = quota.parse_kimi_usages(load_fixture("malformed_kimi.json"))
        self.assertEqual(wins, {})

    def test_empty_or_nonobject_body_no_throw(self):
        for body in ({}, {"limits": []}, [], None, "x", 42,
                     {"limits": "not-a-list"}):
            self.assertEqual(quota.parse_kimi_usages(body), {})


# ---------------------------------------------------------------------------
# parse_glm_quota — C-Q2 glm 双窗（epoch-ms 重置 + 类型过滤 + 排序映射）
# ---------------------------------------------------------------------------

class TestParseGlmQuota(unittest.TestCase):
    def test_real_fixture_sorted_first_short_last_weekly(self):
        wins = quota.parse_glm_quota(load_fixture("glm_quota_limit.json"))
        self.assertEqual(wins["short"][0], 12)
        self.assertEqual(wins["weekly"][0], 8)
        self.assertEqual(wins["short"][1], quota._to_reset_iso(1789990380000))
        self.assertEqual(wins["weekly"][1], quota._to_reset_iso(1790683200000))

    def test_type_filter_and_malformed_entries(self):
        wins = quota.parse_glm_quota(load_fixture("malformed_glm.json"))
        # PROMPT_LIMIT 过滤 / percentage "n/a" 弃 / null 弃 / 非对象弃；
        # reset 非法字符串窗口保留（gcli parity），省 ↻ 由渲染层处理
        self.assertEqual(wins["short"], (33, "not-a-number"))
        self.assertNotIn("weekly", wins)

    def test_single_limit_only_short(self):
        body = {"data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 44,
             "nextResetTime": 1789990380000}]}}
        wins = quota.parse_glm_quota(body)
        self.assertIn("short", wins)
        self.assertNotIn("weekly", wins)

    def test_missing_data_no_throw(self):
        for body in ({}, {"data": None}, {"data": {}},
                     {"data": {"limits": "x"}}, [], "x"):
            self.assertEqual(quota.parse_glm_quota(body), {})


# ---------------------------------------------------------------------------
# format_reset — C-Q3 相对时间（<1m 省略 / 时 / 天）
# ---------------------------------------------------------------------------

class TestFormatReset(unittest.TestCase):
    def test_minutes(self):
        self.assertEqual(quota.format_reset(iso_at(59), NOW_MS), "59m")
        self.assertEqual(quota.format_reset(iso_at(1), NOW_MS), "1m")

    def test_hours_with_and_without_remainder(self):
        self.assertEqual(quota.format_reset(iso_at(133), NOW_MS), "2h13m")
        self.assertEqual(quota.format_reset(iso_at(90), NOW_MS), "1h30m")
        self.assertEqual(quota.format_reset(iso_at(240), NOW_MS), "4h")

    def test_days_with_and_without_remainder(self):
        self.assertEqual(quota.format_reset(iso_at(3000), NOW_MS), "2d2h")
        self.assertEqual(quota.format_reset(iso_at(2880), NOW_MS), "2d")

    def test_expired_or_now_omitted(self):
        self.assertIsNone(quota.format_reset(iso_at(0), NOW_MS))
        self.assertIsNone(quota.format_reset(iso_at(-5), NOW_MS))

    def test_garbage_iso_none(self):
        self.assertIsNone(quota.format_reset("not-a-number", NOW_MS))
        self.assertIsNone(quota.format_reset(None, NOW_MS))


# ---------------------------------------------------------------------------
# level_dot / render_report — 渲染（阈值 85/60 对齐 gcli QUOTA_HIGH/MID）
# ---------------------------------------------------------------------------

class TestLevelDot(unittest.TestCase):
    def test_boundaries(self):
        self.assertEqual(quota.level_dot([85]), "🔴")
        self.assertEqual(quota.level_dot([84]), "🟡")
        self.assertEqual(quota.level_dot([60]), "🟡")
        self.assertEqual(quota.level_dot([59]), "🟢")

    def test_max_across_windows(self):
        self.assertEqual(quota.level_dot([4, 75]), "🟡")
        self.assertEqual(quota.level_dot([75, 91]), "🔴")
        self.assertEqual(quota.level_dot([4]), "🟢")

    def test_empty_caution(self):
        self.assertEqual(quota.level_dot([]), "🟡")


def make_result(names, is_current=False, windows=None, error=False):
    return {
        "display_name": quota.display_name({"names": names}),
        "names": names,
        "is_current": is_current,
        "kind": "glm",
        "windows": windows if windows is not None else {},
        "error": error,
    }


class TestRenderReport(unittest.TestCase):
    def test_title_and_double_windows(self):
        out = quota.render_report([
            make_result(["glm lastest"],
                        windows={"short": (12, iso_at(200)),
                                 "weekly": (45, iso_at(3000))}),
        ], NOW_MS)
        self.assertIn("套餐限额", out)
        self.assertIn("5h 12% ↻3h20m", out)
        self.assertIn("周窗 45% ↻2d2h", out)
        self.assertIn("｜", out)

    def test_status_dot_uses_max_pct(self):
        out = quota.render_report([
            make_result(["a"], windows={"short": (91, iso_at(133)),
                                        "weekly": (4, iso_at(3000))}),
        ], NOW_MS)
        self.assertIn("🔴", out)
        out2 = quota.render_report([
            make_result(["b"], windows={"short": (62, iso_at(65)),
                                        "weekly": (75, iso_at(7200))}),
        ], NOW_MS)
        self.assertIn("🟡", out2)

    def test_current_marker_and_merged_count(self):
        out = quota.render_report([
            make_result(["glm flash lastest", "glm lastest"], is_current=True,
                        windows={"short": (4, iso_at(30))}),
        ], NOW_MS)
        self.assertIn("glm flash lastest（等 2 个条目）· 当前使用中", out)

    def test_failed_entry_degrades(self):
        out = quota.render_report([make_result(["kimi"], error=True)], NOW_MS)
        self.assertIn("⚠️ 暂时无法获取", out)
        self.assertNotIn("5h", out)

    def test_missing_window_segment_degrades(self):
        out = quota.render_report([
            make_result(["a"], windows={"short": (42, iso_at(133))}),
        ], NOW_MS)
        self.assertIn("5h 42% ↻2h13m", out)
        self.assertIn("⚠️ 暂时无法获取", out)

    def test_expired_reset_omits_arrow(self):
        out = quota.render_report([
            make_result(["a"], windows={"short": (42, iso_at(-5))}),
        ], NOW_MS)
        self.assertIn("5h 42%", out)
        self.assertNotIn("↻", out)

    def test_purity_no_ansi(self):
        samples = [
            make_result(["a"], windows={"short": (91, iso_at(133)),
                                        "weekly": (75, iso_at(3000))}),
            make_result(["b"], windows={"short": (4, iso_at(30))}),
            make_result(["c"], windows={"weekly": (60, iso_at(1440))}),
            make_result(["d"], error=True),
            make_result(["e"], windows={}),
        ]
        for r in samples:
            self.assertNotIn("\x1b", quota.render_report([r], NOW_MS))

    def test_token_never_in_output(self):
        # 红线：collect_targets → render 全链路，token 值与「Bearer」字样不得出现
        rows = [("kimi", "https://api.kimi.com/coding/",
                 "SUPER-SECRET-TOKEN", False)]
        targets = quota.collect_targets(rows)
        results = [{
            "display_name": quota.display_name(t),
            "names": t["names"],
            "is_current": t["is_current"],
            "kind": t["kind"],
            "windows": {},
            "error": True,
        } for t in targets]
        out = quota.render_report(results, NOW_MS)
        self.assertNotIn("SUPER-SECRET-TOKEN", out)
        self.assertNotIn("Bearer", out)


# ---------------------------------------------------------------------------
# collect_targets — 域名分类 + (kind, token) 去重
# ---------------------------------------------------------------------------

class TestCollectTargets(unittest.TestCase):
    ROWS = [
        ("glm flash lastest", "https://open.bigmodel.cn/api/anthropic", "tok-A", False),
        ("glm flash echo", "https://open.bigmodel.cn/api/anthropic", "tok-B", True),
        ("glm lastest", "https://open.bigmodel.cn/api/anthropic", "tok-A", False),
        ("kimi", "https://api.kimi.com/coding/", "sk-kimi", False),
        ("deepseek-flash", "https://api.deepseek.com/anthropic", "sk-ds", False),
        ("PackyCode", "https://slb-v1.api.fan", "sk-pk", False),
        ("Claude Official", None, None, False),
        ("broken-config", "not a url", "tok-x", False),
    ]

    def setUp(self):
        self.targets = quota.collect_targets(self.ROWS)

    def test_dedup_same_kind_token(self):
        self.assertEqual(len(self.targets), 3)
        first = self.targets[0]
        self.assertEqual(first["kind"], "glm")
        self.assertEqual(first["names"],
                         ["glm flash lastest", "glm lastest"])
        # is_current 按组内任一条目 OR
        self.assertTrue(self.targets[1]["is_current"])
        self.assertFalse(first["is_current"])

    def test_display_name_suffix(self):
        self.assertEqual(quota.display_name(self.targets[0]),
                         "glm flash lastest（等 2 个条目）")
        self.assertEqual(quota.display_name(self.targets[1]), "glm flash echo")

    def test_unsupported_skipped(self):
        names = [n for t in self.targets for n in t["names"]]
        for gone in ("deepseek-flash", "PackyCode", "Claude Official",
                     "broken-config"):
            self.assertNotIn(gone, names)

    def test_kind_and_urls(self):
        self.assertEqual(self.targets[2]["kind"], "kimi")
        self.assertEqual(self.targets[2]["url"],
                         "https://api.kimi.com/coding/v1/usages")

    def test_empty_rows(self):
        self.assertEqual(quota.collect_targets([]), [])


# ---------------------------------------------------------------------------
# parse_stdin / strip_trigger / filter_targets — 输入侧容错
# ---------------------------------------------------------------------------

class TestStdinSide(unittest.TestCase):
    def test_parse_stdin_valid(self):
        self.assertEqual(quota.parse_stdin('{"query":"kimi","sessionId":"s"}'),
                         {"query": "kimi"})

    def test_parse_stdin_tolerant(self):
        for raw in ("", "not-json", "[]", "null", '{"query":123}'):
            self.assertEqual(quota.parse_stdin(raw), {"query": ""})

    def test_strip_trigger(self):
        self.assertEqual(quota.strip_trigger("gcli"), "")
        self.assertEqual(quota.strip_trigger("gcli kimi"), "kimi")
        self.assertEqual(quota.strip_trigger("限额"), "")
        self.assertEqual(quota.strip_trigger("套餐 glm"), "glm")
        self.assertEqual(quota.strip_trigger("用量 kimi"), "kimi")
        self.assertEqual(quota.strip_trigger("GCLI Kimi"), "Kimi")
        self.assertEqual(quota.strip_trigger("kimi"), "kimi")
        self.assertEqual(quota.strip_trigger("quota"), "quota")
        self.assertEqual(quota.strip_trigger("limit kimi"), "limit kimi")
        self.assertEqual(quota.strip_trigger(None), "")

    def test_strip_trigger_prefix_branch(self):
        """W2 半截触发词前缀分支（s2p6 六例 1:1，对齐 Swift stripKeywordPrefix）。"""
        # 正例："gc" 是 "gcli" 的非空真前缀
        self.assertEqual(quota.strip_trigger("gc"), "")
        # 边界：完整词（既有完全剥离）
        self.assertEqual(quota.strip_trigger("gcli"), "")
        # 边界：剥离剩余（既有分支优先级更高）
        self.assertEqual(quota.strip_trigger("gcli kimi"), "kimi")
        # 边界：中文 keyword 前缀
        self.assertEqual(quota.strip_trigger("限"), "")
        self.assertEqual(quota.strip_trigger("套"), "")
        # 反例：非任何触发词前缀 → 原样（作过滤词）
        self.assertEqual(quota.strip_trigger("kim"), "kim")
        # 反例：空串早返
        self.assertEqual(quota.strip_trigger(""), "")
        # 反例：比触发词长且非完整命中 → 原样
        self.assertEqual(quota.strip_trigger("gclix"), "gclix")

    def test_filter_targets_case_insensitive_any_name(self):
        rows = [("kimi", "https://api.kimi.com/coding/", "sk", False)]
        targets = quota.collect_targets(rows)
        self.assertEqual(len(quota.filter_targets(targets, "KIMI")), 1)
        self.assertEqual(quota.filter_targets(targets, "glm"), [])
        merged = quota.collect_targets(TestCollectTargets.ROWS)
        # 组内任一条目名命中即保留（display 名是首个，副名也能检索到组）
        self.assertEqual(len(quota.filter_targets(merged, "glm")), 2)
        self.assertEqual(len(quota.filter_targets(merged, "glm lastest")), 1)
        self.assertEqual(len(quota.filter_targets(merged, "")), 3)


# ---------------------------------------------------------------------------
# render_card — W3 卡片通道（BUDDY_OUTPUT_CARD，契约规约 card JSON schema）
# ---------------------------------------------------------------------------

class TestRenderCard(unittest.TestCase):
    def test_schema_fields_and_title_contains_gcli(self):
        """s1p3/s3p1 谓词：title 含「gcli」字样；条目含 name/level/badge + windows[label/percent/reset]。"""
        results = [
            make_result(["kimi"], is_current=True,
                        windows={"short": (12, iso_at(200)),
                                 "weekly": (45, iso_at(3000))}),
            make_result(["glm-4.6"],
                        windows={"short": (91, iso_at(65))}),
        ]
        card = quota.render_card(results, NOW_MS)
        self.assertIn("gcli", card["title"])
        self.assertIn("2 个", card["title"])
        self.assertEqual(len(card["entries"]), 2)
        e0 = card["entries"][0]
        self.assertEqual(e0["name"], "kimi")
        self.assertEqual(e0["badge"], "使用中")
        self.assertIn("badge", e0)                       # badge 字段恒序列化（可空）
        self.assertEqual(e0["level"], "ok")
        self.assertEqual(e0["windows"][0],
                         {"label": "5h", "percent": 12, "reset": "3h20m"})
        self.assertEqual(e0["windows"][1]["label"], "周窗")
        # badge 空串（非 current）仍存在
        self.assertIn("badge", card["entries"][1])
        self.assertEqual(card["entries"][1]["badge"], "")

    def test_clamp_both_directions(self):
        """s7p2 谓词：percent=120 → 100 / percent=-5 → 0（产出前 clamp，双侧防御插件侧）。"""
        card = quota.render_card([
            make_result(["a"], windows={"short": (120, iso_at(133))}),
            make_result(["b"], windows={"short": (-5, iso_at(133))}),
        ], NOW_MS)
        self.assertEqual(card["entries"][0]["windows"][0]["percent"], 100)
        self.assertEqual(card["entries"][1]["windows"][0]["percent"], 0)

    def test_level_thresholds_match_level_dot(self):
        """阈值沿用 level_dot：<60 ok / 60-85 warn / ≥85 danger / 无数据 warn。"""
        def level_for(windows):
            card = quota.render_card([make_result(["x"], windows=windows)], NOW_MS)
            return card["entries"][0]["level"]

        self.assertEqual(level_for({"short": (85, iso_at(30))}), "danger")
        self.assertEqual(level_for({"short": (84, iso_at(30))}), "warn")
        self.assertEqual(level_for({"short": (60, iso_at(30))}), "warn")
        self.assertEqual(level_for({"short": (59, iso_at(30))}), "ok")
        self.assertEqual(level_for({}), "warn")

    def test_failed_entry_warn_with_empty_windows(self):
        card = quota.render_card([make_result(["kimi"], error=True)], NOW_MS)
        self.assertEqual(card["entries"][0]["level"], "warn")
        self.assertEqual(card["entries"][0]["windows"], [])

    def test_missing_window_row_omitted(self):
        card = quota.render_card([
            make_result(["a"], windows={"short": (42, iso_at(133))}),
        ], NOW_MS)
        self.assertEqual(len(card["entries"][0]["windows"]), 1)
        self.assertEqual(card["entries"][0]["windows"][0]["label"], "5h")

    def test_no_token_in_card(self):
        """s3p1 红线：token 值 / 「Bearer」字样不落 card JSON。"""
        rows = [("kimi", "https://api.kimi.com/coding/", "SUPER-SECRET-TOKEN", True)]
        targets = quota.collect_targets(rows)
        results = [{
            "display_name": quota.display_name(t),
            "names": t["names"],
            "is_current": t["is_current"],
            "kind": t["kind"],
            "windows": {"short": (12, iso_at(200))},
            "error": False,
        } for t in targets]
        card = quota.render_card(results, NOW_MS)
        text = json.dumps(card, ensure_ascii=False)
        self.assertNotIn("SUPER-SECRET-TOKEN", text)
        self.assertNotIn("Bearer", text)


# ---------------------------------------------------------------------------
# main 写 BUDDY_OUTPUT_CARD 文件 — W3 通道（env 缺失/写失败静默，stdout 恒兜底）
# ---------------------------------------------------------------------------

class _FakeStdin:
    def isatty(self):
        return False

    def read(self):
        return '{"query":"","sessionId":"t","cwd":"/tmp"}'


class TestMainCardChannel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="quota-card-test-")
        cc_dir = os.path.join(self.tmp, ".cc-switch")
        os.makedirs(cc_dir)
        self.db_path = os.path.join(cc_dir, "cc-switch.db")
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "CREATE TABLE providers "
            "(name TEXT, settings_config TEXT, is_current INTEGER, app_type TEXT)")
        conn.execute(
            "INSERT INTO providers VALUES ('kimi', ?, 1, 'claude')",
            (json.dumps({"env": {
                "ANTHROPIC_BASE_URL": "https://api.kimi.com/coding/",
                "ANTHROPIC_AUTH_TOKEN": "UNITTEST-TOKEN-VALUE"}}),))
        conn.commit()
        conn.close()

    def tearDown(self):
        for root, _, files in os.walk(self.tmp, topdown=False):
            for f in files:
                os.remove(os.path.join(root, f))
            os.rmdir(root)

    def _run_main(self, card_path):
        """进程内跑 quota.main()：fixture 假 DB + mock fetch（hermetic，零网络）。返回 (rc, stdout)。"""
        env = dict(os.environ)
        env["HOME"] = self.tmp
        env.pop("BUDDY_OUTPUT_CARD", None)
        if card_path:
            env["BUDDY_OUTPUT_CARD"] = card_path
        fake_out = io.StringIO()
        with mock.patch.object(quota, "fetch_quota_body",
                               return_value=load_fixture("kimi_usages.json")), \
             mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(sys, "stdin", _FakeStdin()), \
             mock.patch.object(sys, "stdout", fake_out):
            rc = quota.main()
        return rc, fake_out.getvalue()

    def test_main_writes_card_file_when_env_set(self):
        card_path = os.path.join(self.tmp, "out.card.json")
        rc, stdout = self._run_main(card_path)
        self.assertEqual(rc, 0)
        with io.open(card_path, encoding="utf-8") as f:
            card = json.load(f)
        self.assertIn("gcli", card["title"])
        self.assertGreaterEqual(len(card["entries"]), 1)
        e = card["entries"][0]
        for key in ("name", "level", "badge", "windows"):
            self.assertIn(key, e)
        self.assertGreaterEqual(len(e["windows"]), 1)
        for w in e["windows"]:
            self.assertIn("label", w)
            self.assertIn("percent", w)
            self.assertIn("reset", w)
        # 红线：card 文件全文不含 token 字样
        with io.open(card_path, encoding="utf-8") as f:
            raw = f.read()
        self.assertNotIn("UNITTEST-TOKEN-VALUE", raw)
        self.assertNotIn("Bearer", raw)
        # stdout 恒有兜底文本（人类可读报告）
        self.assertIn("套餐限额", stdout)

    def test_main_no_env_no_file_written(self):
        rc, stdout = self._run_main(None)
        self.assertEqual(rc, 0)
        self.assertIn("套餐限额", stdout)
        leftovers = [f for f in os.listdir(self.tmp) if f.endswith(".card.json")]
        self.assertEqual(leftovers, [], "env 缺失时不写任何 card 文件")

    def test_main_write_failure_silent_exit0_stdout_fallback(self):
        # 指向不存在目录 → 写失败静默忽略；stdout 恒有兜底文本；恒 exit 0
        card_path = os.path.join(self.tmp, "no-such-dir", "out.card.json")
        rc, stdout = self._run_main(card_path)
        self.assertEqual(rc, 0)
        self.assertIn("套餐限额", stdout)

    def test_main_db_missing_no_card_written(self):
        # DB 缺失 → run 早退无 card → 不写文件；stdout 降级文案
        env_home = os.path.join(self.tmp, "empty-home")
        os.makedirs(env_home)
        card_path = os.path.join(self.tmp, "should-not-exist.card.json")
        env = dict(os.environ)
        env["HOME"] = env_home
        env["BUDDY_OUTPUT_CARD"] = card_path
        fake_out = io.StringIO()
        with mock.patch.object(sys, "stdin", _FakeStdin()), \
             mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(sys, "stdout", fake_out):
            rc = quota.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(card_path), "DB 缺失路径不得写 card")
        self.assertIn("套餐限额", fake_out.getvalue())


if __name__ == "__main__":
    unittest.main()
