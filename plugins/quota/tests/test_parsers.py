# -*- coding: utf-8 -*-
"""quota 插件协议纯函数单元测试。

用例语义移植自 gcli（~/workspace/honeydo/packages/gcli/src/）：
- cli.ts:548-820  buildQuotaRequest / parseKimiUsages / parseGlmQuota / formatReset
- quota-color.acceptance.test.ts      （阈值 85/60 边界、双窗独立判定）
- format-quota-purity.acceptance.test.ts（纯文本输出无 ANSI、过期 reset 省略 ↻）

约定：畸形输入一律降级不抛错（缺窗口 ≠ crash）。
"""

import json
import os
import sys
import unittest
from datetime import datetime, timezone

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
        self.assertEqual(quota.strip_trigger("quota"), "")
        self.assertEqual(quota.strip_trigger("quota kimi"), "kimi")
        self.assertEqual(quota.strip_trigger("限额"), "")
        self.assertEqual(quota.strip_trigger("套餐 glm"), "glm")
        self.assertEqual(quota.strip_trigger("limit kimi"), "kimi")
        self.assertEqual(quota.strip_trigger("QUOTA Kimi"), "Kimi")
        self.assertEqual(quota.strip_trigger("kimi"), "kimi")
        self.assertEqual(quota.strip_trigger(None), "")

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


if __name__ == "__main__":
    unittest.main()
