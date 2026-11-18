#!/bin/bash
# AnyPlay: ставить формули Homebrew та всі їхні залежності зі збірок («пляшок») для старшої macOS.
# Програма несе ці бібліотеки в собі, тож запускається на тій macOS, для якої вони зібрані, а не лише на системі машини GitHub.
# Використання: scripts/brew-bottles-for.sh arm64_sequoia qt@6 ffmpeg ...
set -u
TAG=$1; shift
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
# Список формул Homebrew з мережі знає лише збірки для системи цієї машини; повний список збірок є у сховищі homebrew/core
export HOMEBREW_NO_INSTALL_FROM_API=1
brew tap --force homebrew/core >/dev/null 2>&1 || brew tap homebrew/core --force
echo "Збірки $TAG для qtbase: $(brew info --json=v2 qtbase 2>/dev/null | grep -c "\"$TAG\"")"
ALL=$( (brew deps --union --topological "$@"; printf '%s\n' "$@") | awk '!seen[$0]++')
echo "Формул: $(echo "$ALL" | wc -l | tr -d ' ')"
ok=0; fallback=""
for f in $ALL; do
  if brew fetch --force --bottle-tag="$TAG" "$f" >/dev/null 2>&1 && p=$(brew --cache --bottle-tag="$TAG" "$f") && [[ -e "$p" ]]; then
    brew uninstall --ignore-dependencies "$f" >/dev/null 2>&1 || true
    if brew install --ignore-dependencies --force "$p" >/tmp/brew-bottle.log 2>&1; then ok=$((ok+1)); continue; fi
    tail -5 /tmp/brew-bottle.log
  fi
  fallback="$fallback $f"; brew install --force "$f" >/dev/null 2>&1 || true
done
echo "Зі збірок $TAG: $ok. Звичайні (не вдалося):${fallback:- немає}"
