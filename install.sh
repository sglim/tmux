#!/usr/bin/env bash
# tmux 설정 설치 — ~/.tmux.conf 와 ~/.local/bin 의 스크립트를 이 저장소로 심볼릭 링크한다.
#
#   ./install.sh               tmux 설정 + 스크립트 + TPM·플러그인
#   ./install.sh --claude      + Claude Code 훅·상태줄을 ~/.claude/settings.json 에 합친다(jq 필요)
#   ./install.sh --no-plugins  TPM·플러그인 설치는 건너뛴다
#   ./install.sh --uninstall   이 저장소를 가리키는 링크만 지운다(백업은 그대로 둔다)
#
# 이미 있던 파일은 지우지 않고 <파일>.bak.<시각> 으로 옮긴다. 다시 돌려도 안전하다.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
TS=$(date +%Y%m%d-%H%M%S)
CLAUDE=0
PLUGINS=1
UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --claude) CLAUDE=1 ;;
        --no-plugins) PLUGINS=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "알 수 없는 옵션: $arg (도움말: ./install.sh --help)" >&2; exit 1 ;;
    esac
done

link() { # link <원본> <대상>
    local src=$1 dst=$2
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "  = $dst"
        return
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        mv "$dst" "$dst.bak.$TS"
        echo "  백업 $dst → $dst.bak.$TS"
    fi
    ln -s "$src" "$dst"
    echo "  + $dst"
}

unlink_ours() { # 이 저장소를 가리키는 링크만 지운다
    local dst=$1
    if [ -L "$dst" ] && [[ "$(readlink "$dst")" == "$REPO"/* ]]; then
        rm "$dst"
        echo "  - $dst"
    fi
}

if [ "$UNINSTALL" = 1 ]; then
    unlink_ours "$HOME/.tmux.conf"
    for f in "$REPO"/bin/*; do unlink_ours "$BIN/$(basename "$f")"; done
    echo "끝. 예전 설정은 ~/.tmux.conf.bak.* 에 있습니다. Claude 훅은 ~/.claude/settings.json.bak.* 로 되돌리세요."
    exit 0
fi

# tmux 3.3 이상이 필요하다(allow-passthrough, extended-keys).
if command -v tmux >/dev/null; then
    ver=$(tmux -V | sed -E 's/[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
    read -r major minor <<<"$ver"
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 3 ]; }; then
        echo "⚠️  $(tmux -V) — tmux 3.3 이상을 권합니다." >&2
    fi
else
    echo "⚠️  tmux 가 없습니다. 먼저 설치하세요(macOS: brew install tmux)." >&2
fi

echo "tmux 설정"
link "$REPO/tmux.conf" "$HOME/.tmux.conf"

echo "스크립트 → $BIN"
mkdir -p "$BIN"
for f in "$REPO"/bin/*; do link "$f" "$BIN/$(basename "$f")"; done

if [ "$PLUGINS" = 1 ]; then
    echo "TPM·플러그인"
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
        git clone --depth 1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
    fi
    "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null && echo "  플러그인 설치 완료"
fi

if [ "$CLAUDE" = 1 ]; then
    echo "Claude Code 훅·상태줄"
    command -v jq >/dev/null || { echo "jq 가 필요합니다(macOS: brew install jq)." >&2; exit 1; }
    settings="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    # settings.json 에는 env 의 키 같은 비밀값이 들어가기도 한다 — 백업도 원본 권한 그대로(-p) 둔다.
    cp -p "$settings" "$settings.bak.$TS"
    echo "  백업 $settings → $settings.bak.$TS"
    # 이벤트마다 예전 claude-tmux-state 훅을 걷어 내고 새로 붙인다(여러 번 돌려도 하나만 남는다).
    # 상태줄은 비어 있을 때만 넣는다 — 이미 쓰는 상태줄을 덮지 않는다.
    # 결과는 남만 읽을 수 없는 임시 파일에 먼저 쓴다 — jq 가 실패해도 settings.json 이 비지 않는다.
    tmp="$settings.tmp.$TS"
    trap 'rm -f "$tmp"' EXIT
    (umask 077; jq --slurpfile add "$REPO/claude/settings.json" '
        ($add[0]) as $a
        | .hooks = (reduce ($a.hooks | to_entries[]) as $e (.hooks // {};
            .[$e.key] = (((.[$e.key] // [])
                | map(select(any(.hooks[]?; (.command // "") | test("claude-tmux-state")) | not)))
                + $e.value)))
        | .statusLine = (.statusLine // $a.statusLine)
    ' "$settings.bak.$TS" > "$tmp") || { echo "  $settings 를 JSON 으로 읽지 못해 바꾸지 않았습니다." >&2; exit 1; }
    cat "$tmp" > "$settings"   # 덮어쓰기(cat >)라 원래 파일의 권한·소유자가 그대로 남는다
    if [ "$(jq -r '.statusLine.command // ""' "$settings")" != "$(jq -r '.statusLine.command' "$REPO/claude/settings.json")" ]; then
        echo "  상태줄은 이미 쓰던 것이 있어 그대로 뒀습니다. 컨텍스트 % 를 보려면 statusLine.command 를"
        echo "  \$HOME/.local/bin/claude-statusline 으로 바꾸세요."
    fi
    echo "  훅 $(jq '.hooks | length' "$REPO/claude/settings.json")개 이벤트 반영"
fi

if [ -n "${TMUX:-}" ]; then
    tmux source-file "$HOME/.tmux.conf" && echo "지금 tmux 에 다시 읽혔습니다."
else
    echo "끝. tmux 를 새로 띄우면 적용됩니다."
fi
case ":$PATH:" in *":$BIN:"*) ;; *) echo "참고: $BIN 이 PATH 에 없습니다(tmux 설정은 전체 경로로 불러서 상관없습니다)." ;; esac
