#!/usr/bin/env bash
# 并发加速版：当前目录下
#   - 目录 => 755
#   - 文件 => 644
#   - 属主:属组 => www:www
# 白名单：.git/  .well-known/  .user.ini  以及当前脚本本身($0)
# 输出：逐条“已修改 / 保留 / 失败(含原因)” + 汇总统计

set -euo pipefail
LC_ALL=C

TARGET_USER="www"
TARGET_GROUP="www"
JOBS=""
SCRIPT_NAME="$(basename "$0")"     # 运行中的脚本名
SCRIPT_PATH="./${SCRIPT_NAME}"      # 在当前目录的相对形式，供 find 排除

# 解析参数
while getopts ":j:" opt; do
  case "$opt" in
    j) JOBS="$OPTARG" ;;
    *) ;;
  esac
done
shift $((OPTIND-1))

# 并发度
if [[ -z "${JOBS}" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS=4
  fi
fi
[[ "$JOBS" -lt 1 ]] && JOBS=1

echo "=== 并发权限修复脚本开始 ==="
echo "工作目录：$(pwd)"
echo "目标属主:属组：${TARGET_USER}:${TARGET_GROUP}"
echo "目录权限：755    文件权限：644"
echo "白名单跳过：./.git/  ./.well-known/  ./.user.ini  ./${SCRIPT_NAME}"
echo "并发度：$JOBS"
echo

# 预检查
if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
  echo "⚠️  警告：系统中不存在用户 '${TARGET_USER}'，chown 可能失败。"
fi
if ! getent group "${TARGET_GROUP}" >/dev/null 2>&1; then
  echo "⚠️  警告：系统中不存在用户组 '${TARGET_GROUP}'，chown 可能失败。"
fi
echo

# 白名单提示
for p in ".git" ".well-known" ".user.ini" "${SCRIPT_NAME}"; do
  if [[ -e "$p" ]]; then
    if [[ -d "$p" ]]; then
      echo "白名单：$p （目录）— 已跳过"
    else
      echo "白名单：$p （文件）— 已跳过"
    fi
  fi
done
echo

# 临时日志
MODIFIED_LOG="$(mktemp)"
KEPT_LOG="$(mktemp)"
FAILED_LOG="$(mktemp)"
cleanup() { rm -f "$MODIFIED_LOG" "$KEPT_LOG" "$FAILED_LOG"; }
trap cleanup EXIT

# 通用 find 过滤（跳过白名单，且不改符号链接）
find_common_excludes=(
  -path "./.git" -prune -o
  -path "./.well-known" -prune -o
  -name ".user.ini" -prune -o
  -path "$SCRIPT_PATH" -prune -o
  -path "./tabler-temp" -prune -o
  ! -type l
)

# 1) 并发 chown（逐个执行，失败单独记录）
echo "▶ 正在并发校正属主属组为 ${TARGET_USER}:${TARGET_GROUP} ..."
find . "${find_common_excludes[@]}" -print0 \
| xargs -0 -P "${JOBS}" -I{} sh -c '
  if chown '"${TARGET_USER}"':'"${TARGET_GROUP}"' -- "{}" 2>err; then
    : # 不输出；详细输出在 chmod 阶段给到
  else
    echo "失败：{}  —— chown '"${TARGET_USER}"':'"${TARGET_GROUP}"' 失败：$(cat err)" >&2
  fi
  rm -f err
' 2>>"$FAILED_LOG"

# 2) 目录权限 => 755（仅修改不符合的）
echo "▶ 正在并发修正【目录】权限为 755 ..."
find . "${find_common_excludes[@]}" -type d ! -perm 755 -print0 \
| xargs -0 -P "${JOBS}" -I{} sh -c '
  if chmod 755 "{}" 2>err; then
    echo "已修改：{}  —— chmod->755"
  else
    echo "失败：{}  —— chmod 755 失败：$(cat err)" >&2
  fi
  rm -f err
' >>"$MODIFIED_LOG" 2>>"$FAILED_LOG"

# 目录已符合
echo "▶ 正在并发标记【目录】已符合规则 ..."
find . "${find_common_excludes[@]}" -type d -perm 755 -user "${TARGET_USER}" -group "${TARGET_GROUP}" -print0 \
| xargs -0 -P "${JOBS}" -I{} sh -c '
  echo "保留：{}  —— 已符合（mode=755 owner='"${TARGET_USER}"' group='"${TARGET_GROUP}"'）"
' >>"$KEPT_LOG"

# 3) 文件权限 => 644（仅修改不符合的；同时排除当前脚本自身）
echo "▶ 正在并发修正【文件】权限为 644 ..."
find . "${find_common_excludes[@]}" -type f ! -perm 644 -print0 \
| xargs -0 -P "${JOBS}" -I{} sh -c '
  # 若是当前脚本自身，永远跳过
  if [ "{}" = "./'"${SCRIPT_NAME}"'" ]; then
    echo "保留：{}  —— 当前脚本自身，已跳过" >>"'"$KEPT_LOG"'"
    exit 0
  fi
  if chmod 644 "{}" 2>err; then
    echo "已修改：{}  —— chmod->644"
  else
    echo "失败：{}  —— chmod 644 失败：$(cat err)" >&2
  fi
  rm -f err
' >>"$MODIFIED_LOG" 2>>"$FAILED_LOG"

# 文件已符合
echo "▶ 正在并发标记【文件】已符合规则 ..."
find . "${find_common_excludes[@]}" -type f -perm 644 -user "${TARGET_USER}" -group "${TARGET_GROUP}" -print0 \
| xargs -0 -P "${JOBS}" -I{} sh -c '
  # 若是当前脚本自身，也标记为保留
  if [ "{}" = "./'"${SCRIPT_NAME}"'" ]; then
    echo "保留：{}  —— 当前脚本自身，已跳过"
  else
    echo "保留：{}  —— 已符合（mode=644 owner='"${TARGET_USER}"' group='"${TARGET_GROUP}"'）"
  fi
' >>"$KEPT_LOG"

echo
echo "=== 明细输出（已修改） ==="
[[ -s "$MODIFIED_LOG" ]] && cat "$MODIFIED_LOG" || echo "（无）"

echo
echo "=== 明细输出（保留） ==="
[[ -s "$KEPT_LOG" ]] && cat "$KEPT_LOG" || echo "（无）"

echo
echo "=== 明细输出（失败，含原因） ==="
[[ -s "$FAILED_LOG" ]] && cat "$FAILED_LOG" || echo "（无）"

modified_count=$(wc -l < "$MODIFIED_LOG" | awk '{print $1}')
kept_count=$(wc -l < "$KEPT_LOG" | awk '{print $1}')
failed_count=$(wc -l < "$FAILED_LOG" | awk '{print $1}')

echo
echo "=== 处理完成 ==="
echo "统计：已修改 ${modified_count} 项；保留 ${kept_count} 项；失败 ${failed_count} 项"
exit 0