#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AKShare 本地 Collector（PROV-3a，ADR-DATA007 进程外隔离方案）。

DATA007 合规要点（本脚本是唯一允许 Python 的位置）：
  - 独立 macOS 进程运行，可独立启动 / 崩溃 / 升级；App 进程不 import Python。
  - 可选安装：默认 App 与 iOS 不打包本脚本（SPM exclude，见 macos-app/Package.swift）。
  - 只产 ProviderRecord JSONL 到 staging 目录 + manifest.json；不写 Canonical、
    不碰 GRDB —— Canonical 化由 Swift 侧 Pipeline（SchemaValidator → Factory →
    Commit）完成。
  - 多 dataset（DATA007 §Decision 5）：股票 / 指数 / 基金净值 / 基金持仓 / 宏观，
    每 dataset 独立 staging 文件、独立异常处理，单 dataset 失败不影响其他。

跨语言 schema 契约（与 Swift ProviderRecord Codable 字节对齐，DATA010 §1）：
  - 顶层字段 camelCase：providerID{rawValue} / providerCode{scheme,value} /
    effectiveAt / publishedAt / ingestedAt / kind / rawPayload / reliabilityClass / jurisdiction
  - 日期 ISO8601 UTC "YYYY-MM-DDTHH:MM:SSZ"（无小数秒——Swift .iso8601 策略拒收带微秒的串）
  - kind / reliabilityClass / jurisdiction 用 enum rawValue（DAILY_BAR / COMMUNITY_AGGREGATED / CN）
  - rawPayload：payload JSON（camelCase）UTF-8 → base64 字符串
  - 数值一律定点输出（Decimal → 非科学计数字符串），避免 float 表示误差

CN 交易日界：A 股日期（YYYY-MM-DD）归一化到 Asia/Shanghai 当日 00:00 的 UTC 瞬时
（如 2024-07-01 → 2024-06-30T16:00:00Z），与 Swift 侧
EastmoneyResponseParser.normalizeToTradingDay 产出一致，跨源去重才能对上同一天。

退出码：0 = 全部请求 dataset 成功；1 = 部分/全部 dataset 失败（manifest 仍落盘）；
2 = 环境错误（缺 akshare / 配置不可读）；超时由调用方 watchdog 杀进程（无退出码）。

离线自检：`--selftest` 不 import akshare、不联网，用固定样本数据走同一条
序列化 + 落盘路径，供 Swift 侧跨语言契约测试（AKShareCollectorContractTests）
与 watchdog 测试使用。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo

COLLECTOR_VERSION = "0.1.0"
PROVIDER_ID = "akshare"
RELIABILITY_CLASS = "COMMUNITY_AGGREGATED"  # ADR-DATA006：AKShare 属社区聚合档
JURISDICTION = "CN"

CN_TZ = ZoneInfo("Asia/Shanghai")
UTC = timezone.utc

# dataset 名（与 Swift AKShareDataset.rawValue 对齐；新增 dataset 时 Swift 侧
# 旧版本会忽略 manifest 里的未知 key，前向兼容）。
DATASET_STOCK_DAILY = "stock_daily"
DATASET_INDEX_DAILY = "index_daily"
DATASET_FUND_NAV = "fund_nav"
DATASET_FUND_HOLDINGS = "fund_holdings"
DATASET_MACRO_CHINA = "macro_china"

ALL_DATASETS = [
    DATASET_STOCK_DAILY,
    DATASET_INDEX_DAILY,
    DATASET_FUND_NAV,
    DATASET_FUND_HOLDINGS,
    DATASET_MACRO_CHINA,
]

# 默认抓取配置（--config 可整体覆盖；示例见 collector_config.example.json）。
DEFAULT_CONFIG: Dict[str, Any] = {
    DATASET_STOCK_DAILY: {"symbols": ["600519", "000858"]},
    DATASET_INDEX_DAILY: {"symbols": ["000300", "000905"]},
    DATASET_FUND_NAV: {"funds": ["110022"]},
    DATASET_FUND_HOLDINGS: {"funds": ["110022"], "years": ["2024"]},
    DATASET_MACRO_CHINA: {"series": ["gdp_yearly"]},
}

# 宏观序列 → AKShare 接口名 + MacroPayload 元数据（单位/频率随序列声明，
# 不从响应里猜；isSeasonallyAdjusted 上游不披露，如实置 false 不伪造）。
MACRO_SERIES: Dict[str, Dict[str, str]] = {
    "gdp_yearly": {
        "api": "macro_china_gdp_yearly",
        "unit": "PERCENT",
        "frequency": "QUARTERLY",
    },
    "cpi_yearly": {
        "api": "macro_china_cpi_yearly",
        "unit": "PERCENT",
        "frequency": "MONTHLY",
    },
}


# ---------------------------------------------------------------------------
# JSON 序列化（定点数值，零 float 通道）
# ---------------------------------------------------------------------------

def dumps_compact(obj: Any) -> str:
    """递归紧凑 JSON。Decimal 用 format(d,'f') 输出非科学计数定点串，
    保证 Swift Decimal 按数字字面量逐位精确解析（float repr 有引入
    二进制误差的理论风险，payload 全链路 Decimal 消除它）。"""
    parts: List[str] = []
    _write_json(obj, parts)
    return "".join(parts)


def _write_json(obj: Any, out: List[str]) -> None:
    if obj is None:
        out.append("null")
    elif obj is True:
        out.append("true")
    elif obj is False:
        out.append("false")
    elif isinstance(obj, str):
        out.append(json.dumps(obj, ensure_ascii=False))
    elif isinstance(obj, int):
        out.append(str(obj))
    elif isinstance(obj, float):
        if not math.isfinite(obj):
            raise ValueError(f"non-finite float leaked into payload: {obj!r}")
        out.append(repr(obj))
    elif isinstance(obj, Decimal):
        if not obj.is_finite():
            raise ValueError(f"non-finite Decimal leaked into payload: {obj!r}")
        out.append(format(obj, "f"))
    elif isinstance(obj, dict):
        out.append("{")
        first = True
        for key, value in obj.items():
            if not first:
                out.append(",")
            first = False
            out.append(json.dumps(str(key), ensure_ascii=False))
            out.append(":")
            _write_json(value, out)
        out.append("}")
    elif isinstance(obj, (list, tuple)):
        out.append("[")
        first = True
        for value in obj:
            if not first:
                out.append(",")
            first = False
            _write_json(value, out)
        out.append("]")
    else:
        raise TypeError(f"unsupported JSON type: {type(obj)!r}")


# 延迟导入：dumps_compact 签名标注用字符串 Decimal，此处真实导入。
from decimal import Decimal, InvalidOperation  # noqa: E402


def to_decimal(raw: Any) -> Optional[Decimal]:
    """AKShare 单元格值 → Decimal。空串 / '-' / 'None' / 非有限 → None。"""
    if raw is None:
        return None
    if isinstance(raw, Decimal):
        return raw if raw.is_finite() else None
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int,)):
        return Decimal(raw)
    if isinstance(raw, float):
        if not math.isfinite(raw):
            return None
        return Decimal(repr(raw))
    text = str(raw).strip().replace(",", "")
    if not text or text in {"-", "--", "None", "nan", "NaN", ""}:
        return None
    try:
        value = Decimal(text)
    except InvalidOperation:
        return None
    return value if value.is_finite() else None


def to_int(raw: Any) -> Optional[int]:
    """成交量 / 持股数等整数字段。非整数（含 None）→ None（字段可缺，不丢行）。"""
    value = to_decimal(raw)
    if value is None:
        return None
    integral = value.to_integral_value()
    if value != integral:
        return None
    return int(integral)


# ---------------------------------------------------------------------------
# 日期 / 时间归一化
# ---------------------------------------------------------------------------

def iso_z(utc_dt: datetime) -> str:
    """UTC 时刻 → 'YYYY-MM-DDTHH:MM:SSZ'（截断微秒：Swift .iso8601 拒收小数秒）。"""
    return utc_dt.astimezone(UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def cn_day_to_utc(day_text: Any) -> Optional[str]:
    """'2024-07-01'（或带时分秒的前缀）→ 上海当日 00:00 的 UTC 瞬时 ISO 串。"""
    if day_text is None:
        return None
    text = str(day_text).strip()
    if len(text) < 10:
        return None
    try:
        naive = datetime.strptime(text[:10], "%Y-%m-%d")
    except ValueError:
        return None
    return iso_z(naive.replace(tzinfo=CN_TZ).astimezone(UTC))


_QUARTER_RE = re.compile(r"(\d{4})\s*年\s*([1-4])\s*季度")
_QUARTER_END = {1: (3, 31), 2: (6, 30), 3: (9, 30), 4: (12, 31)}


def parse_quarter(raw: Any) -> Optional[Tuple[int, int]]:
    """'2024年1季度股票投资明细' / '2024年1季度' → (year, quarter)。"""
    if raw is None:
        return None
    match = _QUARTER_RE.search(str(raw))
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def quarter_start_utc(year: int, quarter: int) -> str:
    """观测期起始（FRED 惯例：GDP Q1 dated 1-01）→ 上海当日 00:00 UTC 瞬时。"""
    month = 3 * (quarter - 1) + 1
    naive = datetime(year, month, 1)
    return iso_z(naive.replace(tzinfo=CN_TZ).astimezone(UTC))


def quarter_end_utc(year: int, quarter: int) -> str:
    """持仓报告截止（季度末）→ 上海当日 00:00 UTC 瞬时。"""
    month, day = _QUARTER_END[quarter]
    naive = datetime(year, month, day)
    return iso_z(naive.replace(tzinfo=CN_TZ).astimezone(UTC))


# ---------------------------------------------------------------------------
# ProviderRecord 组装（Swift Codable 字节对齐）
# ---------------------------------------------------------------------------

def cn_price(value: Decimal) -> Dict[str, Any]:
    return {"value": value, "currency": "CNY"}


def make_record(
    *,
    scheme: str,
    value: str,
    effective_at: str,
    kind: str,
    payload: Dict[str, Any],
    ingested_at: str,
    published_at: Optional[str] = None,
) -> Dict[str, Any]:
    """组装一条 ProviderRecord dict。

    published_at：上游不披露公布时间的数据集（AKShare 宏观 / 持仓无 realtime
    字段）默认等于 effective_at（与 Swift 侧 EastmoneyHoldingRecordBuilder 同一
    惯例：保留源时间戳，不发明）。有真实公布时间的数据集显式传入。
    """
    payload_json = dumps_compact(payload)
    return {
        # providerID / providerCode 均为 RawRepresentable 单值合成：Swift 把
        # DataProviderID 编码为裸字符串 "akshare"（非 {"rawValue": ...}），
        # ProviderCode 的两个字段同理退化为裸字符串。
        "providerID": PROVIDER_ID,
        "providerCode": {"scheme": scheme, "value": value},
        "effectiveAt": effective_at,
        "publishedAt": published_at or effective_at,
        "ingestedAt": ingested_at,
        "kind": kind,
        "rawPayload": base64.b64encode(payload_json.encode("utf-8")).decode("ascii"),
        "reliabilityClass": RELIABILITY_CLASS,
        "jurisdiction": JURISDICTION,
    }


# ---------------------------------------------------------------------------
# dataset 抓取器（akshare 延迟导入；schema 漂移 → 单行丢弃 + 计数，整表零有效行才算失败）
# ---------------------------------------------------------------------------

def fetch_stock_daily(ak: Any, cfg: Dict[str, Any], ctx: "RunContext") -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """A 股个股日线（stock_zh_a_hist，adjust='' raw 不复权）→ DAILY_BAR。"""
    records: List[Dict[str, Any]] = []
    dropped: Dict[str, int] = {"malformed_row": 0}
    for symbol in cfg.get("symbols", []):
        df = ak.stock_zh_a_hist(
            symbol=symbol, period="daily",
            start_date=ctx.start_date, end_date=ctx.end_date, adjust="",
        )
        for row in df.to_dict("records"):
            day = cn_day_to_utc(row.get("日期"))
            o, h = to_decimal(row.get("开盘")), to_decimal(row.get("最高"))
            low, c = to_decimal(row.get("最低")), to_decimal(row.get("收盘"))
            if day is None or None in (o, h, low, c):
                dropped["malformed_row"] += 1
                continue
            records.append(make_record(
                scheme="stock_symbol", value=str(symbol), effective_at=day,
                kind="DAILY_BAR", ingested_at=ctx.ingested_at,
                payload={
                    "rawOpen": cn_price(o), "rawHigh": cn_price(h),
                    "rawLow": cn_price(low), "rawClose": cn_price(c),
                    "volume": to_int(row.get("成交量")),
                    "adjustmentFactor": Decimal(1),  # raw 不复权，不伪造复权因子
                    "fxRate": None,
                },
            ))
    return records, dropped


def fetch_index_daily(ak: Any, cfg: Dict[str, Any], ctx: "RunContext") -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """指数日线（index_zh_a_hist）→ DAILY_BAR，scheme=index_code。"""
    records: List[Dict[str, Any]] = []
    dropped: Dict[str, int] = {"malformed_row": 0}
    for symbol in cfg.get("symbols", []):
        df = ak.index_zh_a_hist(
            symbol=symbol, period="daily",
            start_date=ctx.start_date, end_date=ctx.end_date,
        )
        for row in df.to_dict("records"):
            day = cn_day_to_utc(row.get("日期"))
            o, h = to_decimal(row.get("开盘")), to_decimal(row.get("最高"))
            low, c = to_decimal(row.get("最低")), to_decimal(row.get("收盘"))
            if day is None or None in (o, h, low, c):
                dropped["malformed_row"] += 1
                continue
            records.append(make_record(
                scheme="index_code", value=str(symbol), effective_at=day,
                kind="DAILY_BAR", ingested_at=ctx.ingested_at,
                payload={
                    "rawOpen": cn_price(o), "rawHigh": cn_price(h),
                    "rawLow": cn_price(low), "rawClose": cn_price(c),
                    "volume": to_int(row.get("成交量")),
                    "adjustmentFactor": Decimal(1),
                    "fxRate": None,
                },
            ))
    return records, dropped


def fetch_fund_nav(ak: Any, cfg: Dict[str, Any], ctx: "RunContext") -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """场外基金净值（单位净值走势 + 累计净值走势，按日合并）→ NAV_OBSERVATION。

    cumulativeDividendPerShare 上游不披露 → None（不伪造 0，与天天基金链路同口径）。
    """
    records: List[Dict[str, Any]] = []
    dropped: Dict[str, int] = {"malformed_row": 0, "missing_accumulated": 0}
    for fund in cfg.get("funds", []):
        unit_df = ak.fund_open_fund_info_em(symbol=str(fund), indicator="单位净值走势")
        try:
            acc_df = ak.fund_open_fund_info_em(symbol=str(fund), indicator="累计净值走势")
            accumulated = {
                str(row.get("净值日期"))[:10]: to_decimal(row.get("累计净值"))
                for row in acc_df.to_dict("records")
            }
        except Exception:  # 累计净值缺失是合法缺口（部分基金无该序列）
            accumulated = {}
        for row in unit_df.to_dict("records"):
            day_text = str(row.get("净值日期"))[:10]
            day = cn_day_to_utc(day_text)
            nav = to_decimal(row.get("单位净值"))
            if day is None or nav is None:
                dropped["malformed_row"] += 1
                continue
            acc = accumulated.get(day_text)
            if acc is None:
                dropped["missing_accumulated"] += 1
            records.append(make_record(
                scheme="fund_code", value=str(fund), effective_at=day,
                kind="NAV_OBSERVATION", ingested_at=ctx.ingested_at,
                payload={
                    "unitNAV": cn_price(nav),
                    "accumulatedNAV": cn_price(acc) if acc is not None else None,
                    "cumulativeDividendPerShare": None,
                },
            ))
    return records, dropped


def fetch_fund_holdings(ak: Any, cfg: Dict[str, Any], ctx: "RunContext") -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """基金季度持仓（fund_portfolio_hold_em，按季度聚合）→ FUND_HOLDING_SNAPSHOT。

    上游只有报告期标签（'2024年2季度股票投资明细'），无公告日 →
    effectiveAt = 季度末、publishedAt = effectiveAt（不发明公布时间）。
    """
    records: List[Dict[str, Any]] = []
    dropped: Dict[str, int] = {"malformed_position": 0, "unparsable_quarter": 0}
    for fund in cfg.get("funds", []):
        by_quarter: Dict[Tuple[int, int], List[Dict[str, Any]]] = {}
        for year in cfg.get("years", ["2024"]):
            df = ak.fund_portfolio_hold_em(symbol=str(fund), date=str(year))
            for row in df.to_dict("records"):
                quarter = parse_quarter(row.get("季度"))
                if quarter is None:
                    dropped["unparsable_quarter"] += 1
                    continue
                code = str(row.get("股票代码") or "").strip()
                weight_pct = to_decimal(row.get("占净值比例"))
                if not code or weight_pct is None or not (Decimal(0) < weight_pct <= Decimal(100)):
                    dropped["malformed_position"] += 1
                    continue
                shares = to_decimal(row.get("持股数"))
                market_value = to_decimal(row.get("持仓市值"))
                by_quarter.setdefault(quarter, []).append({
                    "providerID": PROVIDER_ID,
                    "providerCode": {"scheme": "stock_symbol", "value": code},
                    "weight": {"value": weight_pct / Decimal(100)},
                    "shares": shares,
                    "marketValue": cn_price(market_value) if market_value is not None else None,
                    "isDisclosed": True,
                })
        for (year, quarter), positions in sorted(by_quarter.items()):
            total = min(Decimal(1), sum((p["weight"]["value"] for p in positions), Decimal(0)))
            records.append(make_record(
                scheme="fund_code", value=str(fund),
                effective_at=quarter_end_utc(year, quarter),
                kind="FUND_HOLDING_SNAPSHOT", ingested_at=ctx.ingested_at,
                payload={
                    "reportPeriod": f"Q{quarter}",
                    "positions": positions,
                    "disclosedWeightTotal": {"value": total},
                },
            ))
    return records, dropped


def fetch_macro_china(ak: Any, cfg: Dict[str, Any], ctx: "RunContext") -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """中国宏观序列（macro_china_*）→ MACRO_OBSERVATION。

    AKShare 宏观无 FRED 式 realtime_start，publishedAt = effectiveAt（观测期起始，
    FRED 惯例 GDP Q1 dated 1-01）；PIT 精确公布时间由 FRED 链路负责，此处如实缺省。
    """
    records: List[Dict[str, Any]] = []
    dropped: Dict[str, int] = {"malformed_row": 0}
    for series_name in cfg.get("series", []):
        meta = MACRO_SERIES.get(series_name)
        if meta is None:
            dropped[f"unknown_series:{series_name}"] = 1
            continue
        df = getattr(ak, meta["api"])()
        for row in df.to_dict("records"):
            quarter = parse_quarter(row.get("季度"))
            value = to_decimal(row.get("同比增长"))
            if quarter is None or value is None:
                dropped["malformed_row"] += 1
                continue
            year, q = quarter
            records.append(make_record(
                scheme="ak_macro_series", value=series_name,
                effective_at=quarter_start_utc(year, q),
                kind="MACRO_OBSERVATION", ingested_at=ctx.ingested_at,
                payload={
                    "value": value,
                    "unit": meta["unit"],
                    "frequency": meta["frequency"],
                    "isSeasonallyAdjusted": False,
                    "basePeriod": None,
                },
            ))
    return records, dropped


DATASET_FETCHERS = {
    DATASET_STOCK_DAILY: fetch_stock_daily,
    DATASET_INDEX_DAILY: fetch_index_daily,
    DATASET_FUND_NAV: fetch_fund_nav,
    DATASET_FUND_HOLDINGS: fetch_fund_holdings,
    DATASET_MACRO_CHINA: fetch_macro_china,
}


def load_akshare() -> Any:
    try:
        import akshare  # noqa: PLC0415 延迟导入：selftest / 环境探测不需要它
    except ImportError as exc:
        raise RuntimeError(
            f"akshare 未安装（可选组件，需自行 pip install -r requirements.txt）: {exc}"
        ) from exc
    return akshare


def classify_exception(exc: Exception) -> Tuple[str, str]:
    """异常 → (category, message)。category ∈ environment/network/not_found/schema/internal。

    尽力分类 + 永远保留原始异常文本（可诊断输出）；不可识别归 internal。
    """
    name = type(exc).__name__
    module = type(exc).__module__ or ""
    text = f"{name}: {exc}"
    if isinstance(exc, (ImportError, RuntimeError)) and "akshare" in str(exc):
        return "environment", text
    if any(key in name for key in ("Connection", "Timeout", "HTTP", "ReadTimeout", "ConnectTimeout")):
        return "network", text
    if any(key in text.lower() for key in ("timeout", "timed out", "connection", "ssl", "暂时", "超时")):
        return "network", text
    if name in {"KeyError", "JSONDecodeError", "ValueError"} or "requests" not in module and name.endswith("Error"):
        return "schema", text
    if "404" in text or "not found" in text.lower():
        return "not_found", text
    return "internal", text


# ---------------------------------------------------------------------------
# 自检（离线，不 import akshare；走与生产完全相同的组装/序列化/落盘路径）
# ---------------------------------------------------------------------------

def selftest_build(ingested_at: str) -> Dict[str, Tuple[List[Dict[str, Any]], Dict[str, int]]]:
    """固定样本数据，跨语言契约测试的事实源（Swift 侧断言这些具体值）。"""
    return {
        DATASET_STOCK_DAILY: (
            [
                make_record(
                    scheme="stock_symbol", value="600519", kind="DAILY_BAR",
                    effective_at=cn_day_to_utc("2024-07-01") or "", ingested_at=ingested_at,
                    payload={
                        "rawOpen": cn_price(Decimal("1425.00")), "rawHigh": cn_price(Decimal("1440.00")),
                        "rawLow": cn_price(Decimal("1418.55")), "rawClose": cn_price(Decimal("1436.28")),
                        "volume": 2896700, "adjustmentFactor": Decimal(1), "fxRate": None,
                    },
                ),
                make_record(
                    scheme="stock_symbol", value="600519", kind="DAILY_BAR",
                    effective_at=cn_day_to_utc("2024-07-02") or "", ingested_at=ingested_at,
                    payload={
                        "rawOpen": cn_price(Decimal("1441.00")), "rawHigh": cn_price(Decimal("1451.98")),
                        "rawLow": cn_price(Decimal("1432.61")), "rawClose": cn_price(Decimal("1445.00")),
                        "volume": 2513400, "adjustmentFactor": Decimal(1), "fxRate": None,
                    },
                ),
            ],
            {"malformed_row": 0},
        ),
        DATASET_INDEX_DAILY: (
            [
                make_record(
                    scheme="index_code", value="000300", kind="DAILY_BAR",
                    effective_at=cn_day_to_utc("2024-07-01") or "", ingested_at=ingested_at,
                    payload={
                        "rawOpen": cn_price(Decimal("3468.42")), "rawHigh": cn_price(Decimal("3493.75")),
                        "rawLow": cn_price(Decimal("3460.00")), "rawClose": cn_price(Decimal("3484.50")),
                        "volume": 15203000000, "adjustmentFactor": Decimal(1), "fxRate": None,
                    },
                ),
            ],
            {"malformed_row": 0},
        ),
        DATASET_FUND_NAV: (
            [
                make_record(
                    scheme="fund_code", value="110022", kind="NAV_OBSERVATION",
                    effective_at=cn_day_to_utc("2024-07-01") or "", ingested_at=ingested_at,
                    payload={
                        "unitNAV": cn_price(Decimal("3.1830")),
                        "accumulatedNAV": cn_price(Decimal("4.8241")),
                        "cumulativeDividendPerShare": None,
                    },
                ),
                make_record(
                    scheme="fund_code", value="110022", kind="NAV_OBSERVATION",
                    effective_at=cn_day_to_utc("2024-07-02") or "", ingested_at=ingested_at,
                    payload={
                        "unitNAV": cn_price(Decimal("3.1871")),
                        "accumulatedNAV": cn_price(Decimal("4.8282")),
                        "cumulativeDividendPerShare": None,
                    },
                ),
            ],
            {"malformed_row": 0, "missing_accumulated": 0},
        ),
        DATASET_FUND_HOLDINGS: (
            [
                make_record(
                    scheme="fund_code", value="110022", kind="FUND_HOLDING_SNAPSHOT",
                    effective_at=quarter_end_utc(2024, 2), ingested_at=ingested_at,
                    payload={
                        "reportPeriod": "Q2",
                        "positions": [
                            {
                                "providerID": PROVIDER_ID,
                                "providerCode": {"scheme": "stock_symbol", "value": "600519"},
                                "weight": {"value": Decimal("0.0998")},
                                "shares": Decimal("4456600"),
                                "marketValue": cn_price(Decimal("6417643.13")),
                                "isDisclosed": True,
                            },
                            {
                                "providerID": PROVIDER_ID,
                                "providerCode": {"scheme": "stock_symbol", "value": "000858"},
                                "weight": {"value": Decimal("0.0876")},
                                "shares": Decimal("3122000"),
                                "marketValue": cn_price(Decimal("5633813.24")),
                                "isDisclosed": True,
                            },
                        ],
                        "disclosedWeightTotal": {"value": Decimal("0.1874")},
                    },
                ),
            ],
            {"malformed_position": 0, "unparsable_quarter": 0},
        ),
        DATASET_MACRO_CHINA: (
            [
                make_record(
                    scheme="ak_macro_series", value="gdp_yearly", kind="MACRO_OBSERVATION",
                    effective_at=quarter_start_utc(2024, 1), ingested_at=ingested_at,
                    payload={
                        "value": Decimal("5.3"), "unit": "PERCENT", "frequency": "QUARTERLY",
                        "isSeasonallyAdjusted": False, "basePeriod": None,
                    },
                ),
                make_record(
                    scheme="ak_macro_series", value="gdp_yearly", kind="MACRO_OBSERVATION",
                    effective_at=quarter_start_utc(2024, 2), ingested_at=ingested_at,
                    payload={
                        "value": Decimal("4.7"), "unit": "PERCENT", "frequency": "QUARTERLY",
                        "isSeasonallyAdjusted": False, "basePeriod": None,
                    },
                ),
            ],
            {"malformed_row": 0},
        ),
    }


# ---------------------------------------------------------------------------
# 落盘（原子写 + sha256；manifest 最后写，存在即代表本轮文件已稳定）
# ---------------------------------------------------------------------------

def write_jsonl_atomic(path: Path, records: List[Dict[str, Any]]) -> str:
    lines = [dumps_compact(record) for record in records]
    blob = ("\n".join(lines) + "\n" if lines else "").encode("utf-8")
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(blob)
    os.replace(tmp, path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json_atomic(path: Path, obj: Any) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(dumps_compact(obj) + "\n", encoding="utf-8")
    os.replace(tmp, path)


class RunContext:
    def __init__(self, start_date: str, end_date: str) -> None:
        self.start_date = start_date
        self.end_date = end_date
        self.ingested_at = iso_z(datetime.now(UTC))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="AKShare 本地 Collector（PROV-3a，DATA007 进程外方案）")
    parser.add_argument("--out-dir", required=True, help="staging 输出目录（manifest.json + {dataset}.jsonl）")
    parser.add_argument("--config", help="JSON 配置文件（覆盖默认抓取标的）")
    parser.add_argument("--dataset", help=f"只跑指定 dataset（逗号分隔；默认全部 {ALL_DATASETS}）")
    parser.add_argument("--start-date", default="20240101", help="行情窗口起（YYYYMMDD）")
    parser.add_argument("--end-date", default="20241231", help="行情窗口止（YYYYMMDD）")
    parser.add_argument("--max-rows", type=int, default=200000, help="单 dataset 行数安全上限（防失控回填）")
    parser.add_argument("--selftest", action="store_true", help="离线自检：不联网不依赖 akshare，产固定样本")
    parser.add_argument("--hang-ms", type=int, default=0, help="启动后先挂起 N 毫秒（watchdog 超时测试用）")
    args = parser.parse_args(argv)

    if args.hang_ms > 0:
        time.sleep(args.hang_ms / 1000.0)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    config = json.loads(json.dumps(DEFAULT_CONFIG))  # deep copy 默认配置
    if args.config:
        try:
            override = json.loads(Path(args.config).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"[akshare-collector] 配置不可读: {exc}", file=sys.stderr)
            return 2
        for key, value in override.items():
            if key in config and isinstance(value, dict):
                config[key].update(value)
            else:
                config[key] = value

    requested = (
        [name.strip() for name in args.dataset.split(",") if name.strip()]
        if args.dataset else list(ALL_DATASETS)
    )
    unknown = [name for name in requested if name not in DATASET_FETCHERS]
    for name in unknown:
        print(f"[akshare-collector] 未知 dataset: {name}（可用: {ALL_DATASETS}）", file=sys.stderr)
    if unknown:
        return 2

    ctx = RunContext(args.start_date, args.end_date)
    manifest: Dict[str, Any] = {
        "collectorVersion": COLLECTOR_VERSION,
        "generatedAt": ctx.ingested_at,
        "mode": "selftest" if args.selftest else "collect",
        "datasets": {},
    }
    datasets: Dict[str, Any] = manifest["datasets"]
    exit_code = 0

    if args.selftest:
        results: Dict[str, Any] = {
            name: {"ok": payload} for name, payload in selftest_build(ctx.ingested_at).items()
            if name in requested
        }
    else:
        try:
            ak = load_akshare()
        except RuntimeError as exc:
            for name in requested:
                datasets[name] = {
                    "status": "error", "recordCount": 0, "droppedMalformed": {},
                    "errorCategory": "environment", "errorMessage": str(exc), "file": None, "sha256": None,
                }
            write_json_atomic(out_dir / "manifest.json", manifest)
            print(f"[akshare-collector] 环境错误: {exc}", file=sys.stderr)
            return 2
        results = {}
        for name in requested:
            try:
                records, dropped = DATASET_FETCHERS[name](ak, config.get(name, {}), ctx)
                if len(records) > args.max_rows:
                    print(
                        f"[akshare-collector] {name}: {len(records)} 行超过上限 {args.max_rows}，"
                        "截断（--max-rows 可调）",
                        file=sys.stderr,
                    )
                    records = records[: args.max_rows]
                if not records:
                    raise ValueError(f"{name}: 抓到 0 条有效记录（标的不覆盖或 schema 漂移）")
                results[name] = {"ok": (records, dropped)}
            except Exception as exc:  # 单 dataset 失败隔离：记录后继续下一个
                category, message = classify_exception(exc)
                results[name] = {"error": (category, message)}

    for name in requested:
        outcome = results.get(name)
        if outcome is None:
            continue
        if "error" in outcome:
            category, message = outcome["error"]
            datasets[name] = {
                "status": "error", "recordCount": 0, "droppedMalformed": {},
                "errorCategory": category, "errorMessage": message, "file": None, "sha256": None,
            }
            exit_code = 1
            print(f"[akshare-collector] {name}: ERROR [{category}] {message}", file=sys.stderr)
            continue
        records, dropped = outcome["ok"]
        file_name = f"{name}.jsonl"
        digest = write_jsonl_atomic(out_dir / file_name, records)
        datasets[name] = {
            "status": "ok", "recordCount": len(records),
            "droppedMalformed": dropped,
            "errorCategory": None, "errorMessage": None,
            "file": file_name, "sha256": digest,
        }
        print(
            f"[akshare-collector] {name}: ok  {len(records)} 条"
            f"（dropped={dropped or '{}'}）→ {file_name}",
        )

    write_json_atomic(out_dir / "manifest.json", manifest)
    print(f"[akshare-collector] manifest → {out_dir / 'manifest.json'}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
