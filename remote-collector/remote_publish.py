#!/usr/bin/env python3
"""远程 staging 发布器（PROV-3b 服务端，ADR-DATA010）。

消费 PROV-3a collector 的 staging 输出（{dataset}.jsonl + manifest.json），
产出 nginx 静态托管的发布根（快照 + 原子指针）：

  {publish_root}/
    snapshots/<时间戳>/      # 一轮发布的完整快照：{dataset}.jsonl +
                             #   manifest.json [+ manifest.sig]，落地后不可变
    snapshot.txt             # 当前快照指针（tmp + rename 原子切换，内容 = 快照目录名）

事务边界：manifest 与签名都在快照目录内完成后才切换 snapshot.txt——签名失败 /
中途崩溃只废弃该快照，线上正在服务的版本不受影响，不会出现
「新 manifest 配旧签名」的错配。保留最近 N 个快照供回滚。

**快照固定读取**：客户端一次 sync 跨多次 HTTP 请求（manifest → 签名 → 文件），
若每次都读可变入口，中途发布会让批次混入两个快照（旧 manifest + 新签名 →
误判篡改）。因此客户端只读一次 snapshot.txt 固定快照 ID，整批从
snapshots/<id>/ 不可变路径读取；nginx 托管整个发布根。

manifest wire 契约（与 Swift RemoteStagingManifest Codable 字节对齐，跨语言
契约测试守护）：
  {"version":1,"collectorVersion":"0.1.0","generatedAt":"2026-08-21T08:00:00Z",
   "files":[{"name":"stock_daily.jsonl","sha256":"<64 位小写 hex>","byteSize":123}]}

manifest 只登记**本轮通过校验的文件**（不是扫描目录）——失败/未请求的旧
dataset 不会带着新 generatedAt 重新上架；generatedAt 取 staging 的产出时间
（新鲜度监控锚定数据本身，不是发布动作）。

签名语义：对 manifest.json 落盘后的**精确字节**签名（含结尾换行）——客户端对
拉取到的原始字节验签，nginx 必须原样托管，不得启用会改写字节的模块。

密钥管理（DATA010 §5 可选验签）：
  --generate-key PATH   生成 Ed25519 私钥（PEM、无口令、0600）写 PATH，
                        stdout 打印公钥 raw 32 字节的 base64（App 端
                        RemoteStagingProvider signaturePublicKey 配置值）
  --signing-key PATH    用 PATH 私钥对本轮 manifest 签名（依赖 cryptography 库）

--generate-key 不依赖 akshare_collector.py（可单文件部署）；发布 / --selftest
模式才按搜索顺序定位 collector（抓取与序列化的单一实现）：
--collector-script 显式路径 → 本脚本同目录（VPS 部署两脚本同放）→ 仓库源码树
默认位置。

凭证边界（DATA010）：本脚本只处理公开市场数据；任何用户私有凭证
（且慢 cookie / 个人持仓）出现在此脚本或其配置中即为违规。

用法：
  # VPS cron 常规链：collector 抓取 → 发布（聚合去重由 collector 的日级抓取承担）
  akshare_collector.py --out-dir /var/lib/collector/staging
  remote_publish.py --staging-dir /var/lib/collector/staging \\
      --publish-dir /var/www/staging --signing-key /etc/collector/ed25519.pem

  # 离线自检（不联网、不依赖 akshare / staging 目录，产固定样本走完整发布路径）
  remote_publish.py --selftest --publish-dir /tmp/publish [--signing-key KEY]

退出码：0 = 发布成功；1 = 没有任何 dataset 通过校验（**不切换 snapshot.txt**，
线上继续服务上一轮快照，客户端靠新鲜度监控降级）；2 = 配置/环境错误
（含 staging 缺少合法 generatedAt——新鲜度锚点不可伪造）。
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

# 本目录是**服务端组件**（PROV-3b），与 macOS App 包（macos-app/）分离；
# 抓取与序列化的单一实现在 PROV-3a 的 akshare_collector.py（App 侧可选组件），
# 延迟导入（--generate-key / --help 不触碰它），不在本脚本重写第二份
# （字节级一致性是跨语言契约的一部分）。
REPO_COLLECTOR = (
    Path(__file__).resolve().parent.parent
    / "macos-app" / "InvestmentIntelligenceV2" / "Collector" / "akshare_collector.py"
)

PUBLISH_MANIFEST_VERSION = 1
SNAPSHOT_KEEP_DEFAULT = 5

# argparse 解析后回填（collector_module 定位 collector 时读取）；None = 默认搜索
_collector_script_override: Optional[str] = None
_COLLECTOR_MODULE: Any = None


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


def collector_module() -> Any:
    """延迟加载 akshare_collector（仅发布 / selftest 路径调用）。"""
    global _COLLECTOR_MODULE
    if _COLLECTOR_MODULE is None:
        script = locate_collector_module(_collector_script_override)
        sys.path.insert(0, str(script.parent))
        import akshare_collector  # noqa: PLC0415

        _COLLECTOR_MODULE = akshare_collector
    return _COLLECTOR_MODULE


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
    # O_CREAT|O_EXCL 一步到位：创建即 0600，不留「先写后 chmod」按 umask
    # （如 0644）暴露私钥的窗口；O_EXCL 同时是覆盖的 race-free 防线
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        print(f"[remote-publish] 拒绝覆盖已有私钥: {path}", file=sys.stderr)
        return 2
    with os.fdopen(fd, "wb") as handle:
        handle.write(pem)
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
# 快照（snapshot）与 current 指针
#
# 客户端一次 sync 跨多次 HTTP 请求（manifest → 签名 → 文件）。若每次请求都
# 读可变入口（指针），中途发布会让批次混入两个快照（旧 manifest + 新签名 →
# 误判篡改）。因此：
# - 服务端把「当前快照」写进 **snapshot.txt 单文件**（tmp + os.replace，
#   原子切换；nginx 直接托管发布根，snapshots/<id>/ 不可变路径可寻址）
# - 客户端只读一次 snapshot.txt 固定快照 ID，整批从 snapshots/<id>/ 读取
# ---------------------------------------------------------------------------

# 快照目录名 = UTC 时间戳（%Y%m%dT%H%M%SZ）+ 可选 -<序号>；指针文件内容校验用
SNAPSHOT_NAME_RE = re.compile(r"^[0-9A-Za-z_-]{1,64}$")

# staging manifest 的 generatedAt（ISO8601 UTC，无小数秒——与 Swift .iso8601 对齐）
ISO_Z_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def new_snapshot_dir(publish_root: Path) -> Path:
    """创建本轮快照目录（publish_root/snapshots/<UTC 时间戳>，重名加序号）。"""
    snapshots = publish_root / "snapshots"
    snapshots.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate = snapshots / stamp
    suffix = 1
    while candidate.exists():
        suffix += 1
        candidate = snapshots / f"{stamp}-{suffix}"
    candidate.mkdir()
    return candidate


def install_file(src: Path, dst: Path) -> None:
    """把 staging 文件放进快照（同文件系统 hardlink，跨设备回退 copy）。"""
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def switch_current_pointer(publish_root: Path, snapshot_dir: Path) -> None:
    """snapshot.txt 原子切换到新快照（tmp + rename，读端只看到完整的新旧之一）。"""
    pointer = publish_root / "snapshot.txt"
    tmp = publish_root / "snapshot.txt.tmp"
    tmp.write_text(snapshot_dir.name + "\n", encoding="utf-8")
    os.replace(tmp, pointer)


def current_pointer_value(publish_root: Path) -> Optional[str]:
    """读当前指针（不存在/不合法返回 None，供 prune 保留判断）。"""
    pointer = publish_root / "snapshot.txt"
    if not pointer.is_file():
        return None
    value = pointer.read_text(encoding="utf-8").strip()
    return value if SNAPSHOT_NAME_RE.match(value) else None


def prune_snapshots(publish_root: Path, keep: int) -> None:
    """保留最近 keep 个快照 + 指针指向的那个，其余清理（回滚窗口之外的数据）。"""
    snapshots = publish_root / "snapshots"
    if not snapshots.is_dir():
        return
    dirs = sorted((d for d in snapshots.iterdir() if d.is_dir()), reverse=True)
    keep_names = {d.name for d in dirs[: max(keep, 1)]}
    if (pinned := current_pointer_value(publish_root)) is not None:
        keep_names.add(pinned)
    for d in dirs:
        if d.name not in keep_names:
            shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------------------
# staging 条目校验（P2：dataset 名 / 文件名 / 路径边界）
# ---------------------------------------------------------------------------

def validated_staging_file(staging_dir: Path, name: str, entry: Dict[str, Any]) -> Optional[Path]:
    """校验 staging manifest 条目并返回安全路径；不合法返回 None（调用方跳过）。

    - dataset 名必须在 ALL_DATASETS 内
    - file 必须严格等于 f"{name}.jsonl"（挡绝对路径 / ../ 穿越 / 陌生文件名）
    - resolve 后必须仍在 staging 目录内（纵深防御）
    """
    ak = collector_module()
    if name not in ak.ALL_DATASETS:
        return None
    if entry.get("file") != f"{name}.jsonl":
        return None
    src = (staging_dir / entry["file"]).resolve()
    if not src.is_relative_to(staging_dir.resolve()):
        return None
    return src


# ---------------------------------------------------------------------------
# 发布
# ---------------------------------------------------------------------------

def finalize_snapshot(
    publish_root: Path,
    snapshot: Path,
    file_entries: List[Dict[str, Any]],
    collector_version: str,
    generated_at: str,
    signing_key: Optional[Path],
) -> bool:
    """快照内完成 manifest（+签名）→ 原子切换 current → 清理旧快照。

    事务边界：切换前快照对外不可见；manifest / 签名 / 数据文件在同一快照内
    成对出现，客户端固定快照 ID 后从不可变路径整批读取，线上永远看不到
    「新 manifest 配旧签名」或半成品目录。
    """
    ak = collector_module()
    manifest = {
        "version": PUBLISH_MANIFEST_VERSION,
        "collectorVersion": collector_version,
        "generatedAt": generated_at,
        "files": file_entries,
    }
    ak.write_json_atomic(snapshot / "manifest.json", manifest)
    if signing_key:
        try:
            sign_manifest(snapshot / "manifest.json", signing_key)
        except Exception as exc:  # 私钥不可读 / cryptography 缺失：废弃快照，线上不动
            shutil.rmtree(snapshot, ignore_errors=True)
            print(f"[remote-publish] 签名失败（快照已废弃，指针未切换）: {exc}", file=sys.stderr)
            return False
    switch_current_pointer(publish_root, snapshot)
    prune_snapshots(publish_root, keep=SNAPSHOT_KEEP_DEFAULT)
    print(f"[remote-publish] snapshot.txt → {snapshot.name}（{len(file_entries)} 文件）")
    return True


def publish_from_staging(staging_dir: Path, publish_root: Path, signing_key: Optional[Path]) -> int:
    """常规模式：读 staging manifest.json，校验后把 ok dataset 装进新快照。"""
    try:
        staging_manifest = json.loads((staging_dir / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"[remote-publish] staging manifest 不可读: {exc}", file=sys.stderr)
        return 2

    # 新鲜度锚点 fail-closed（审查 P1）：generatedAt 缺失/非法时拒绝发布——
    # 伪造为当前时间会让陈旧数据（schema 漂移的受害者）看起来刚刚产出
    generated_at = staging_manifest.get("generatedAt")
    if not isinstance(generated_at, str) or not ISO_Z_RE.match(generated_at):
        print(
            "[remote-publish] staging manifest 缺少合法 generatedAt（ISO8601 UTC），"
            "新鲜度锚点不可伪造，拒绝发布",
            file=sys.stderr,
        )
        return 2
    collector_version = staging_manifest.get("collectorVersion") or collector_module().COLLECTOR_VERSION

    ok_entries = [
        (name, entry)
        for name, entry in staging_manifest.get("datasets", {}).items()
        if entry.get("status") == "ok" and entry.get("file")
    ]
    if not ok_entries:
        # 不切指针：空清单会把客户端新鲜度打穿，且覆盖上一轮有效发布
        print(
            "[remote-publish] staging 中没有任何 status=ok 的 dataset，snapshot.txt 保持不变",
            file=sys.stderr,
        )
        return 1

    snapshot = new_snapshot_dir(publish_root)
    file_entries: List[Dict[str, Any]] = []
    for name, entry in sorted(ok_entries):
        src = validated_staging_file(staging_dir, name, entry)
        if src is None:
            print(f"[remote-publish] {name}: staging 条目非法（dataset 名/文件名/路径越界），跳过", file=sys.stderr)
            continue
        if sha256_hex_of_file(src) != entry.get("sha256"):
            print(f"[remote-publish] {name}: staging sha256 与 manifest 不符，跳过", file=sys.stderr)
            continue
        dst = snapshot / f"{name}.jsonl"
        install_file(src, dst)
        file_entries.append(
            {"name": dst.name, "sha256": sha256_hex_of_file(dst), "byteSize": dst.stat().st_size}
        )

    if not file_entries:
        shutil.rmtree(snapshot, ignore_errors=True)
        print("[remote-publish] 没有任何 dataset 通过校验，snapshot.txt 保持不变", file=sys.stderr)
        return 1

    return 0 if finalize_snapshot(
        publish_root, snapshot, file_entries, collector_version, generated_at, signing_key
    ) else 2


def publish_selftest(publish_root: Path, signing_key: Optional[Path]) -> int:
    """离线自检：固定样本（selftest_build）走与生产相同的序列化 + 发布路径。"""
    ak = collector_module()
    generated_at = ak.iso_z(datetime.now(timezone.utc))
    snapshot = new_snapshot_dir(publish_root)
    file_entries: List[Dict[str, Any]] = []
    for name, (records, _dropped) in ak.selftest_build(generated_at).items():
        dst = snapshot / f"{name}.jsonl"
        digest = ak.write_jsonl_atomic(dst, records)
        file_entries.append({"name": dst.name, "sha256": digest, "byteSize": dst.stat().st_size})
    return 0 if finalize_snapshot(
        publish_root, snapshot, file_entries, ak.COLLECTOR_VERSION, generated_at, signing_key
    ) else 2


def main(argv: Optional[List[str]] = None) -> int:
    global _collector_script_override
    parser = argparse.ArgumentParser(
        description="远程 staging 发布器（PROV-3b 服务端，ADR-DATA010）"
    )
    parser.add_argument("--staging-dir", help="PROV-3a collector 输出目录（常规模式）")
    parser.add_argument("--publish-dir", help="发布根目录（nginx 托管 current/；--generate-key 模式无需）")
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
    _collector_script_override = args.collector_script

    if args.generate_key:
        # 密钥生成不依赖 collector / staging / cryptography 之外的任何环境
        return generate_key(Path(args.generate_key))

    if not args.publish_dir:
        parser.error("需要 --publish-dir（或使用 --generate-key）")

    if not args.selftest and not args.staging_dir:
        parser.error("常规模式需要 --staging-dir（或使用 --selftest）")

    publish_root = Path(args.publish_dir)
    signing_key = Path(args.signing_key) if args.signing_key else None

    if args.selftest:
        return publish_selftest(publish_root, signing_key)
    return publish_from_staging(Path(args.staging_dir), publish_root, signing_key)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # 未预期错误统一 exit 2——裸 traceback 的退出码是 1，
        # 会撞「无可发布 dataset」的语义（如 current 异常时 os.replace 抛错）
        print(f"[remote-publish] 未预期错误: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(2)
