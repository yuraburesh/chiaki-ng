#!/usr/bin/env bash
# AnyPlay 116: джерела libdatachannel для трансляції друзям (CI: Windows і Mac).
# Клонує зафіксовану версію з потрібними підмодулями, з повторами (GitHub інколи обриває з'єднання),
# і перевіряє коміт. CMake потім бере цю теку через -DFETCHCONTENT_SOURCE_DIR_LIBDATACHANNEL=<тека>.
# Версія — та сама, що в cmake/AnyPlayLibDataChannel.cmake.
set -euo pipefail

dest="${1:?тека для джерел}"
tag="v0.24.6"
commit="6b1e2e620f1e37f0eafeee702eaea0043cb305fd"
url="https://github.com/paullouisageneau/libdatachannel.git"

if [[ -f "$dest/CMakeLists.txt" ]] && [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" == "$commit" ]]; then
  echo "libdatachannel $tag вже на місці: $dest"
  exit 0
fi

ok=0
for attempt in 1 2 3 4; do
  rm -rf "$dest"
  if git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dest" \
     && git -C "$dest" submodule update --init --depth 1 deps/plog deps/usrsctp deps/libjuice deps/libsrtp; then
    ok=1
    break
  fi
  echo "Спроба $attempt не вдалась, повтор через $((attempt * 15)) с"
  sleep $((attempt * 15))
done
if [[ $ok != 1 ]]; then
  echo "::error::Не вдалося завантажити libdatachannel $tag"
  exit 1
fi

head=$(git -C "$dest" rev-parse HEAD)
if [[ "$head" != "$commit" ]]; then
  echo "::error::libdatachannel $tag: очікувався коміт $commit, а прийшов $head"
  exit 1
fi
for dep in plog usrsctp libjuice libsrtp; do
  [[ -f "$dest/deps/$dep/CMakeLists.txt" ]] || { echo "::error::немає підмодуля deps/$dep"; exit 1; }
done
echo "libdatachannel $tag ($commit) готова: $dest"
