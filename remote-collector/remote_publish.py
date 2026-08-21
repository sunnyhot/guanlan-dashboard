#!/usr/bin/env python3
"""远程 staging 发布器（PROV-3b 服务端，ADR-DATA010）。

消费 PROV-3a collector 的 staging 输出（{dataset}.jsonl + manifest.json），
产出可直接由 nginx 静态托管的 publish 目录：

  {publish_dir}/
    {dataset}.jsonl     # 从 staging 复制（仅 status=ok 的 dataset）
    manifest.json       # RemoteStagingManifest wire 契约（camelCase + ISO8601 UTC）
    manifest.sig        # Ed25519 签名（raw 64 字节，仅提供 --signing-key 时产出）

wire 契约（与 Swift RemoteStagingManifest Codable 字节对齐，跨语言契约测试守护）：
  {"version":1,"collectorVersion":"0.1.0","generatedAt":"2026-08-21T08:00:00Z",
   "files":[{"name":"stock_daily.jsonl","sha256":"<64 位小写 hex>","byteSize":123}]}

签名语义：对 manifest.json 落盘后的**精确字节**签名（含结尾换行）——客户端对
拉取到的原始字节验签，nginx 必须原样托管，不得启用会改写字节的模块。

密钥管理（DATA010 §5 可选验签）：
  --generate-key PATH   生成 Ed25519 私钥（PEM、无口令、0600）写 PATH，
                        stdout 打印公钥 raw 32 字节的 base64（App 端
                        RemoteStagingProvider signaturePublicKey 配置值）
  --signing-key PATH    用 PATH 私钥对本轮 manifest 签名（依赖 cryptography 库）

凭证边界（DATA010）：本脚本只处理公开市场数据；任何用户私有凭证
（且慢 cookie / 个人持仓）出现在此脚本或其配置中即为违规。

用法：
  # VPS cron 常规链：collector 抓取 → 发布（聚合去重由 collector 的日级抓取承担）
  akshare_collector.py --out-dir /var/lib/collector/staging
  remote_publish.py --staging-dir /var/lib/collector/staging \\
      --publish-dir /var/www/staging --signing-key /etc/collector/ed25519.pem

  # 离线自检（不联网、不依赖 akshare / staging 目录，产固定样本走完整发布路径）
  remote_publish.py --selftest --publish-dir /tmp/publish [--signing-key KEY]

退出码：0 = 发布成功；1 = 没有任何 status=ok 的 dataset（**不覆盖旧 manifest**，
保留上一轮有效发布，客户端继续用旧数据 + 新鲜度监控降级）；2 = 配置/环境错误。
"""

import argparse
import base64
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

# 本目录是**服务端组件**（PROV-3b），与 macOS App 包（macos-app/）分离；
# 抓取与序列化的单一实现在 PROV-3a 的 akshare_collector.py（App 侧可选组件），
# 按搜索顺序定位，不在本脚本重写第二份（字节级一致性是跨语言契约的一部分）。
REPO_COLLECTOR = (
    Path(__file__).resolve().parent.parent
    / "macos-app" / "InvestmentIntelligenceV2" / "Collector" / "akshare_collector.py"
)


def locate_collector_module(explicit: Optional[str]) -> Path:
    """定位 akshare_collector.py。

    搜索顺序：--collector-script 显式路径 → 本脚本同目录（VPS 部署两脚本同放）
    → 仓库源码树默认位置（开发 / 跨语言契约测试从 checkout 直接跑）。
    """
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    here = Path(__file__).resolve().parent
    candidates.append(here / "akshare_collector.py")
    candidates.append(REPO_COLLECTOR)
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    print(
        "[remote-publish] 找不到 akshare_collector.py（搜索: "
        + ", ".join(str(c) for c in candidates)
        + "）；用 --collector-script 指定，或把两脚本放在同一目录",
        file=sys.stderr,
    )
    raise SystemExit(2)


def _explicit_collector_from_argv() -> Optional[str]:
    """在 argparse 之前从 argv 取 --collector-script（import 需要它定位模块）。"""
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--collector-script" and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith("--collector-script="):
            return arg.split("=", 1)[1]
    return None


sys.path.insert(0, str(locate_collector_module(_explicit_collector_from_argv()).parent))
from akshare_collector import (  # noqa: E402
    ALL_DATASETS,
    COLLECTOR_VERSION,
    iso_z,
    selftest_build,
    write_json_atomic,
    write_jsonl_atomic,
)

PUBLISH_MANIFEST_VERSION = 1


def sha256_hex_of_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ---------------------------------------------------------------------------
# Ed25519（可选：仅 --generate-key / --signing-key 时才 import cryptography，
# 无签名部署与离线自检不引入该依赖）
# ---------------------------------------------------------------------------

def load_private_key(path: Path):
    from cryptography.hazmat.primitives import serialization  # noqa: PLC0415

    return serialization.load_pem_private_key(path.read_bytes(), password=None)


def generate_key(path: Path) -> int:
    from cryptography.hazmat.primitives import serialization  # noqa: PLC0415
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (  # noqa: PLC0415
        Ed25519PrivateKey,
    )

    private_key = Ed25519PrivateKey.generate()
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    if path.exists():
        print(f"[remote-publish] 拒绝覆盖已有私钥: {path}", file=sys.stderr)
        return 2
    path.write_bytes(pem)
    os.chmod(path, 0o600)
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    print(base64.b64encode(public_raw).decode("ascii"))
    return 0


def sign_manifest(manifest_path: Path, key_path: Path) -> Path:
    key = load_private_key(key_path)
    # 对磁盘上的最终字节签名（含 write_json_atomic 的结尾换行）——
    # 客户端验的是拉取字节，两侧必须逐字节一致
    signature = key.sign(manifest_path.read_bytes())
    sig_path = manifest_path.with_name("manifest.sig")
    tmp = sig_path.with_suffix(sig_path.suffix + ".tmp")
    tmp.write_bytes(signature)
    os.replace(tmp, sig_path)
    return sig_path


# ---------------------------------------------------------------------------
# 发布
# ---------------------------------------------------------------------------

def publish_from_staging(staging_dir: Path, publish_dir: Path) -> int:
    """常规模式：读 staging manifest.json，复制 ok dataset 到 publish 目录。"""
    staging_manifest_path = staging_dir / "manifest.json"
    try:
        staging_manifest = json.loads(staging_manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"[remote-publish] staging manifest 不可读: {exc}", file=sys.stderr)
        return 2
    ok_entries = [
        (name, entry)
        for name, entry in staging_manifest.get("datasets", {}).items()
        if entry.get("status") == "ok" and entry.get("file")
    ]
    if not ok_entries:
        # 不写 manifest：空清单会把客户端新鲜度打穿，且覆盖上一轮有效发布
        print(
            "[remote-publish] staging 中没有任何 status=ok 的 dataset，保留旧 manifest",
            file=sys.stderr,
        )
        return 1

    publish_dir.mkdir(parents=True, exist_ok=True)
    for name, entry in sorted(ok_entries):
        src = staging_dir / entry["file"]
        dst = publish_dir / f"{name}.jsonl"
        # 校验 staging 自身完整性后再复制（collector manifest 声明的 sha256）
        if sha256_hex_of_file(src) != entry.get("sha256"):
            print(f"[remote-publish] {name}: staging sha256 与 manifest 不符，跳过", file=sys.stderr)
            continue
        dst.write_bytes(src.read_bytes())

    collector_version = staging_manifest.get("collectorVersion", COLLECTOR_VERSION)
    return write_publish_manifest(publish_dir, collector_version)


def publish_selftest(publish_dir: Path) -> int:
    """离线自检：固定样本（selftest_build）走与生产相同的序列化 + 发布路径。"""
    ingested_at = iso_z(datetime.now(timezone.utc))
    publish_dir.mkdir(parents=True, exist_ok=True)
    for name, (records, _dropped) in selftest_build(ingested_at).items():
        write_jsonl_atomic(publish_dir / f"{name}.jsonl", records)
    return write_publish_manifest(publish_dir, COLLECTOR_VERSION)


def write_publish_manifest(publish_dir: Path, collector_version: str) -> int:
    """扫描 publish 目录的 {dataset}.jsonl，写 manifest.json（+可选 manifest.sig）。"""
    known = {f"{name}.jsonl" for name in ALL_DATASETS}
    files: List[Dict[str, Any]] = []
    for path in sorted(publish_dir.glob("*.jsonl")):
        if path.name not in known:
            # publish 目录里只认 collector 产出的 dataset 文件，陌生文件不进清单
            #（防手工放置文件被签名背书）
            continue
        files.append(
            {
                "name": path.name,
                "sha256": sha256_hex_of_file(path),
                "byteSize": path.stat().st_size,
            }
        )
    if not files:
        print("[remote-publish] publish 目录没有可登记的 dataset 文件", file=sys.stderr)
        return 1

    manifest = {
        "version": PUBLISH_MANIFEST_VERSION,
        "collectorVersion": collector_version,
        "generatedAt": iso_z(datetime.now(timezone.utc)),
        "files": files,
    }
    write_json_atomic(publish_dir / "manifest.json", manifest)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="远程 staging 发布器（PROV-3b 服务端，ADR-DATA010）"
    )
    parser.add_argument("--staging-dir", help="PROV-3a collector 输出目录（常规模式）")
    parser.add_argument("--publish-dir", help="nginx 托管的发布目录（--generate-key 模式无需）")
    parser.add_argument("--signing-key", help="Ed25519 私钥 PEM 路径（可选验签）")
    parser.add_argument("--generate-key", help="生成 Ed25519 私钥到该路径并打印公钥 base64")
    parser.add_argument(
        "--collector-script",
        help="akshare_collector.py 路径（默认搜索：脚本同目录 → 仓库源码树位置）",
    )
    parser.add_argument(
        "--selftest", action="store_true",
        help="离线自检：不联网不依赖 staging，产固定样本走完整发布路径",
    )
    args = parser.parse_args(argv)

    if args.generate_key:
        return generate_key(Path(args.generate_key))

    if not args.publish_dir:
        parser.error("需要 --publish-dir（或使用 --generate-key）")

    if not args.selftest and not args.staging_dir:
        parser.error("常规模式需要 --staging-dir（或使用 --selftest）")

    publish_dir = Path(args.publish_dir)

    if args.selftest:
        exit_code = publish_selftest(publish_dir)
    else:
        exit_code = publish_from_staging(Path(args.staging_dir), publish_dir)
    if exit_code != 0:
        return exit_code

    if args.signing_key:
        try:
            sig_path = sign_manifest(publish_dir / "manifest.json", Path(args.signing_key))
        except Exception as exc:  # 私钥不可读 / cryptography 缺失都是环境错误
            print(f"[remote-publish] 签名失败: {exc}", file=sys.stderr)
            return 2
        print(f"[remote-publish] manifest.sig → {sig_path}")

    print(f"[remote-publish] manifest → {publish_dir / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
