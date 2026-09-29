#!/usr/bin/env bash
# fcitx5-classicui-theme.sh — 让 fcitx5 候选框主题跟随 Omarchy 当前主题
# 用法:
#   fcitx5-classicui-theme.sh [主题slug] [--quiet]
#   - 主题slug 省略时使用当前主题 (omarchy theme current)
#   - --quiet 时跳过桌面通知
# 幂等: 主题未变化时不会重启 fcitx5, 可安全被 hook / service / 定时器反复调用
set -euo pipefail

quiet=0
slug=""
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) quiet=1 ;;
    -h|--help)
      echo "Usage: fcitx5-classicui-theme.sh [theme-slug] [--quiet]"
      exit 0 ;;
    *) slug="$arg" ;;
  esac
done

# 同一次切换主题可能同时触发 hook、service 文件监视和启动定时器, 它们写的是同一批
# 文件。加锁串行化, 避免两次运行交错写坏 theme.conf / classicui.conf。
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/omarchy-fcitx5-theme.lock"
flock 9

if [[ -z "$slug" || "$slug" == "current" ]]; then
  current="$(omarchy theme current 2>/dev/null || true)"
  slug="$(printf '%s' "$current" | tr '[:upper:] ' '[:lower:]-')"
fi
slug="$(printf '%s' "$slug" | tr '[:upper:] ' '[:lower:]-')"

theme_dir="$(omarchy theme dir "$slug" 2>/dev/null || true)"
if [[ -z "$theme_dir" || ! -f "$theme_dir/colors.toml" ]]; then
  echo "fcitx5-theme: theme '$slug' colors.toml not found" >&2
  exit 1
fi
colors="$theme_dir/colors.toml"

get() {
  sed -nE "s/^$1[[:space:]]*=[[:space:]]*[\"']?([^\"']*)[\"']?[[:space:]]*$/\1/p" "$colors" | head -1
}

mode="$(get mode)";   [[ -n "$mode" ]]   || mode=dark
bg="$(get background)"; [[ -n "$bg" ]]   || bg="#1e1e2e"
fg="$(get foreground)"; [[ -n "$fg" ]]   || fg="#cdd6f4"
accent="$(get accent)"; [[ -n "$accent" ]] || accent="#89b4fa"
sel="$(get selection)"; [[ -n "$sel" ]]  || sel="$(get muted)"
[[ -n "$sel" ]] || sel="#313244"
dark_bg="$(get darker_background)"; [[ -n "$dark_bg" ]] || dark_bg="$(get dark_background)"
[[ -n "$dark_bg" ]] || dark_bg="#11111b"

# 高亮（选中候选）文字颜色：与面板底色对比——深色主题用深底色文字，浅色主题用浅底色文字
if [[ "$mode" == "light" ]]; then
  # Omarchy 的浅色调色板里 dark_foreground 是"变淡的前景色"而不是"深色文字",
  # lighter_background 也只是比 background 略深的一档。white 主题两者相等
  # (都是 #c0c0c0), 于是候选文字和面板底色同色 —— 候选框整个看不见。
  # 改为与深色分支对称: 正文用 foreground/background, 选中候选在 accent 底上
  # 用 background 色文字。
  hl_text="$bg"
  panel_bg="$bg"
  panel_fg="$fg"
else
  hl_text="$dark_bg"
  panel_bg="$bg"
  panel_fg="$fg"
fi
hl_bg="$accent"
border="$sel"
menu_sep="$(get bright_foreground)"; [[ -n "$menu_sep" ]] || menu_sep="$border"

# 翻页箭头、子菜单箭头、单选点用正文色。
# 试过 muted / dark_foreground 这类"淡一档"的颜色: 在深色主题上对比度只有
# 1.6~2.6:1 (everforest 的 dark_foreground #4f585e 配 #2d353b 基本看不见)。
# 这些图标只有几个像素宽, 是功能件不是装饰, 宁可和正文一样清楚。
glyph="$panel_fg"

# 圆角半径与 9-slice 的关系: classicui 用 [.../Background/Margin] 作九宫格切边,
# 四角按边距大小原样绘制, 中间拉伸。半径必须 <= 边距, 否则圆弧尾部落在拉伸区里,
# 面板一变宽就被抹平。candlelight 的 macOS 主题是 rx=12 配 Margin=10, 这里取 10:
# 切换输入法时那个只有一两个字的提示框, 用 candlelight 的内边距会显得过大。
radius=10
inset=$radius

out="$HOME/.local/share/fcitx5/themes/omarchy-$slug"

# 下面会整目录替换, 先确认 slug 没被污染成路径
if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "fcitx5-theme: refusing to generate for suspicious theme slug '$slug'" >&2
  exit 1
fi

# 生成到暂存目录再整体比对: 现在一个主题有 theme.conf + 两个 svg + 四个图标,
# 只比 theme.conf 已经不够 —— 改了配色却不重启 fcitx5 就看不到变化。
mkdir -p "$(dirname "$out")"
stage="$(mktemp -d "${out}.stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# 面板与高亮的形状: 各一个圆角矩形, 颜色按当前主题取。
# 形状参考 thep0y/fcitx5-themes-candlelight 的 macOS 主题 (MIT), 但这里是按
# 主题重新生成的, 不是复制写死配色的素材。
cat > "$stage/panel.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="39" height="39" x=".5" y=".5" rx="$radius" fill="$panel_bg" stroke="$border"/></svg>
EOF

cat > "$stage/highlight.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" rx="$radius" fill="$hl_bg"/></svg>
EOF

# 翻页按钮等图标从 fcitx5 default 主题取形状, 重新上色。
# default 主题把它们写死成 fill:#c0c0c0 —— 它不知道用户的调色板, 我们知道。
# 上游若改了这个字面量, sed 匹配不到, 图标只是保持灰色, 不会坏。
for img in arrow.svg next.svg prev.svg radio.svg; do
  src="/usr/share/fcitx5/themes/default/$img"
  [[ -f "$src" ]] || continue
  sed "s/fill:#c0c0c0/fill:$glyph/g" "$src" > "$stage/$img"
done

cat > "$stage/theme.conf" <<EOF
[Metadata]
Name=Omarchy $slug
Version=1
Author=Omarchy theme hook
Description=Generated from Omarchy theme: $slug
ScaleWithDPI=True

[InputPanel]
NormalColor=$panel_fg
HighlightCandidateColor=$hl_text
HighlightColor=$panel_fg
# 高亮底由 highlight.svg 画, 这里必须透明, 否则方角色块会盖在圆角药丸下面
HighlightBackgroundColor=#00000000
FullWidthHighlight=True
PageButtonAlignment=Last Candidate

[InputPanel/TextMargin]
Left=12
Right=12
Top=6
Bottom=6

[InputPanel/ContentMargin]
Left=4
Right=4
Top=4
Bottom=4

[InputPanel/Background]
Image=panel.svg

[InputPanel/Background/Margin]
Left=$inset
Right=$inset
Top=$inset
Bottom=$inset

[InputPanel/Highlight]
Image=highlight.svg

[InputPanel/Highlight/Margin]
Left=12
Right=12
Top=6
Bottom=6

[InputPanel/PrevPage]
Image=prev.svg

[InputPanel/PrevPage/ClickMargin]
Left=5
Right=5
Top=4
Bottom=4

[InputPanel/NextPage]
Image=next.svg

[InputPanel/NextPage/ClickMargin]
Left=5
Right=5
Top=4
Bottom=4

[Menu]
NormalColor=$panel_fg
HighlightCandidateColor=$hl_text

[Menu/Background]
Image=panel.svg

[Menu/Background/Margin]
Left=$inset
Right=$inset
Top=$inset
Bottom=$inset

[Menu/ContentMargin]
Left=4
Right=4
Top=4
Bottom=4

[Menu/CheckBox]
Image=radio.svg

[Menu/SubMenu]
Image=arrow.svg

[Menu/Highlight]
Image=highlight.svg

[Menu/Highlight/Margin]
Left=8
Right=8
Top=6
Bottom=6

[Menu/Separator]
Color=$menu_sep

[Menu/TextMargin]
Left=8
Right=8
Top=6
Bottom=6

[AccentColorField]
0=Input Panel Border
1=Input Panel Highlight Candidate Background
2=Input Panel Highlight
3=Menu Border
4=Menu Separator
5=Menu Selected Item Background
EOF

changed=0
if [[ -d "$out" ]] && diff -rq "$stage" "$out" >/dev/null 2>&1; then
  :
else
  rm -rf "$out"
  mkdir -p "$(dirname "$out")"
  mv "$stage" "$out"
  chmod 755 "$out"
  changed=1
fi
trap - EXIT
rm -rf "$stage"

# 写入 classicui 配置
conf="$HOME/.config/fcitx5/conf/classicui.conf"
mkdir -p "$(dirname "$conf")"

# 记录"接管前"的原始主题, 供卸载时还原 (只记录一次)
STATE_DIR="$HOME/.local/state/omarchy-fcitx5-theme"
STATE_FILE="$STATE_DIR/state"
if [[ ! -f "$STATE_FILE" ]]; then
  prev_theme=""
  if [[ -f "$conf" ]]; then
    prev_theme="$(sed -nE 's/^Theme=([^[:space:]]+)[[:space:]]*$/\1/p' "$conf" | head -1 || true)"
  fi
  case "$prev_theme" in
    omarchy-*) prev_theme="" ;;  # 接管前已是本扩展生成的主题, 无法得知更早的值
  esac
  mkdir -p "$STATE_DIR"
  printf 'prev_theme=%s\n' "$prev_theme" > "$STATE_FILE"
fi

if [[ -f "$conf" ]] && grep -q "^Theme=omarchy-$slug\$" "$conf"; then
  : # 已指向当前主题
elif [[ -f "$conf" ]] && grep -q "^Theme=" "$conf"; then
  sed -i "s|^Theme=.*|Theme=omarchy-$slug|" "$conf"
  changed=1
else
  printf 'Theme=omarchy-%s\n' "$slug" >> "$conf"
  changed=1
fi

# 仅在主题实际变化时重启 fcitx5（classicui 只在启动时读主题）
if [[ $changed == 1 ]]; then
  if systemctl --user restart omarchy-fcitx5.service 2>/dev/null; then
    :
  else
    fcitx5-remote -r 2>/dev/null || true
  fi
  if [[ $quiet != 1 ]]; then
    notify-send "fcitx5 主题" "候选框已跟随主题: $slug" 2>/dev/null || true
  fi
fi

exit 0
