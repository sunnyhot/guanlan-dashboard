#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${QIEMAN_CLI_OUTPUT:-$ROOT_DIR/dist/bin/qieman-cli}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

SWIFT_SOURCES=(
  "$ROOT_DIR/macos-app/Support/ValueFormatting.swift"
  "$ROOT_DIR/macos-app/Core/Models/AppEnums.swift"
  "$ROOT_DIR/macos-app/Core/Models/Query.swift"
  "$ROOT_DIR/macos-app/Core/Models/ManagerWatchSettings.swift"
  "$ROOT_DIR/macos-app/Core/Models/SnapshotPayloads.swift"
  "$ROOT_DIR/macos-app/Core/Models/PlatformPayloads.swift"
  "$ROOT_DIR/macos-app/Core/Models/PersonalAsset.swift"
  "$ROOT_DIR/macos-app/Core/Models/UserPortfolio.swift"
  "$ROOT_DIR/macos-app/Core/Models/PersonalWatchlist.swift"
  "$ROOT_DIR/macos-app/Core/Models/PersonalTrade.swift"
  "$ROOT_DIR/macos-app/Core/Models/PersonalPlan.swift"
  "$ROOT_DIR/macos-app/Core/Models/AlfaPortfolioCatalogItem.swift"
  "$ROOT_DIR/macos-app/Core/Models/AlfaHoldingPart.swift"
  "$ROOT_DIR/macos-app/Core/Platform/NativePlatformError.swift"
  "$ROOT_DIR/macos-app/Core/Platform/PlatformActionAssetBuckets.swift"
  "$ROOT_DIR/macos-app/Core/Platform/NativePlatformDTOs.swift"
  "$ROOT_DIR/macos-app/Core/QiemanRequestSigning.swift"
  "$ROOT_DIR/macos-app/Core/QiemanText.swift"
  "$ROOT_DIR/macos-app/Core/JSONFilePersistence.swift"
  "$ROOT_DIR/macos-app/Core/Alfa/QiemanAlfaClient.swift"
  "$ROOT_DIR/macos-app/Core/AlfaPortfolioStore.swift"
  "$ROOT_DIR/macos-app/Core/NativeSnapshotStore.swift"
  "$ROOT_DIR/macos-app/Core/MenuBarTicker/MenuBarTickerTypes.swift"
  "$ROOT_DIR/macos-app/Core/QiemanNativeClient.swift"
  "$ROOT_DIR/macos-app/Core/QiemanPlatformNativeClient.swift"
  "$ROOT_DIR/macos-app/Core/QiemanPlatformNativeClientSupport.swift"
  "$ROOT_DIR/macos-app/Core/QiemanCommandLine.swift"
  "$ROOT_DIR/macos-app/Core/CLI/Contract.swift"
  "$ROOT_DIR/macos-app/Core/CLI/DTOs.swift"
  "$ROOT_DIR/macos-app/CLI/main.swift"
)

swiftc \
  "${SWIFT_SOURCES[@]}" \
  -parse-as-library \
  -O \
  -whole-module-optimization \
  -target "${TARGET_ARCH}-apple-macos${MIN_MACOS_VERSION}" \
  -o "$OUTPUT_PATH"

echo "$OUTPUT_PATH"
