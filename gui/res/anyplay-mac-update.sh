#!/bin/bash
# AnyPlay: заміна програми на Mac. Запускає сама програма перед виходом:
#   anyplay-mac-update.sh <pid> <джерело: .zip з оновленням або AnyPlay.app> <куди: шлях до AnyPlay.app> <файл результату>
# Чекає, доки програма закриється, розпаковує (або копіює) нову версію поруч зі старою, перевіряє підпис,
# знімає карантин і міняє місцями, лишаючи стару як запас. Будь-яка помилка повертає стару версію.
# Якщо macOS не дала замінити програму, нова версія лягає в «Завантаження», Finder показує її,
# а стара програма відкривається й пояснює, що перетягти вручну.
# У файл результату пишемо «ok» або «failed» і (другим рядком) шлях до нової версії для ручного перенесення.

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PID="${1:-}"
SRC="${2:-}"
DEST="${3:-}"
RESULT="${4:-}"
if [[ -z "$PID" || -z "$SRC" || -z "$DEST" || -z "$RESULT" ]]; then
	echo "usage: $0 <pid> <zip|app> <bundle> <result-file>" >&2
	exit 2
fi

LOG="$(dirname "$RESULT")/mac-update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

PARENT="$(dirname "$DEST")"
NAME="$(basename "$DEST")"
STAGE="$PARENT/.anyplay-update-$$"
BACKUP="$PARENT/.anyplay-old-$$.app"
MODE="zip"
[[ "$SRC" == *.app ]] && MODE="copy"

# тимчасова папка з цим скриптом більше не потрібна, коли закінчимо
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cleanup() {
	rm -rf "$STAGE" 2>/dev/null
	case "$SELF_DIR" in
		*/anyplay-update-*) rm -rf "$SELF_DIR" 2>/dev/null ;;
	esac
}
trap cleanup EXIT

finish_ok() {
	log "готово: $DEST"
	printf 'ok\n' > "$RESULT"
	[[ "$MODE" == "zip" ]] && rm -f "$SRC"
	open "$DEST" || log "не вдалося відкрити $DEST"
	exit 0
}

# Нову версію не вдалося поставити на місце: стара лишається, нову (якщо є) кладемо в «Завантаження».
# Третій аргумент «broken» — нова версія пошкоджена, пропонувати її вручну не можна.
fail() {
	local why="$1" new="${2:-}" broken="${3:-}" manual=""
	log "помилка: $why"
	if [[ "$MODE" == "zip" && "$broken" != "broken" ]]; then
		local dir="$HOME/Downloads/AnyPlay оновлення"
		rm -rf "$dir" 2>/dev/null
		if mkdir -p "$dir" 2>/dev/null; then
			if [[ -n "$new" && -d "$new" ]] && mv "$new" "$dir/$NAME" 2>/dev/null; then
				manual="$dir/$NAME"
			elif ditto -x -k "$SRC" "$dir" 2>>"$LOG"; then
				manual="$(find "$dir" -maxdepth 1 -name '*.app' -type d | head -n 1)"
			fi
		fi
		if [[ -n "$manual" ]]; then
			xattr -dr com.apple.quarantine "$manual" 2>/dev/null
			open -R "$manual" 2>/dev/null
		fi
	fi
	printf 'failed\n%s\n' "$manual" > "$RESULT"
	if [[ -d "$DEST" ]]; then
		open "$DEST" 2>/dev/null
	elif [[ "$MODE" == "copy" ]]; then
		open "$SRC" 2>/dev/null
	fi
	exit 1
}

log "старт: pid=$PID src=$SRC dest=$DEST mode=$MODE"

# 1. чекаємо, доки програма закриється (до хвилини), потім закриваємо її самі
for _ in $(seq 1 300); do
	kill -0 "$PID" 2>/dev/null || break
	sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then
	log "програма не закрилась, завершуємо її"
	kill -TERM "$PID" 2>/dev/null
	sleep 3
	kill -KILL "$PID" 2>/dev/null
	sleep 1
fi

[[ -e "$SRC" ]] || fail "немає джерела $SRC"

# 2. нова версія — у прихованій папці поруч зі старою (той самий диск, тож заміна миттєва)
rm -rf "$STAGE" 2>/dev/null
mkdir -p "$STAGE" 2>/dev/null || fail "не вдалося створити $STAGE"
if [[ "$MODE" == "zip" ]]; then
	ditto -x -k "$SRC" "$STAGE" 2>>"$LOG" || fail "не вдалося розпакувати архів"
else
	ditto "$SRC" "$STAGE/$NAME" 2>>"$LOG" || fail "не вдалося скопіювати програму"
fi
NEW="$(find "$STAGE" -maxdepth 1 -name '*.app' -type d | head -n 1)"
[[ -n "$NEW" && -d "$NEW/Contents/MacOS" && -f "$NEW/Contents/Info.plist" ]] || fail "в архіві немає програми" "" broken

# 3. підпис цілий — файл розпакувався без пошкоджень
codesign --verify --deep "$NEW" 2>>"$LOG" || fail "підпис нової версії не сходиться" "" broken
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null

# 4. заміна: стара — у запас, нова — на її місце; якщо щось не так, повертаємо стару
if [[ -e "$DEST" ]]; then
	mv "$DEST" "$BACKUP" 2>>"$LOG" || fail "macOS не дала прибрати стару версію" "$NEW"
fi
if ! mv "$NEW" "$DEST" 2>>"$LOG"; then
	[[ -e "$BACKUP" ]] && mv "$BACKUP" "$DEST" 2>>"$LOG"
	fail "не вдалося поставити нову версію" "$NEW"
fi
if [[ ! -d "$DEST/Contents/MacOS" || -z "$(ls -A "$DEST/Contents/MacOS" 2>/dev/null)" ]]; then
	rm -rf "$DEST" 2>/dev/null
	[[ -e "$BACKUP" ]] && mv "$BACKUP" "$DEST" 2>>"$LOG"
	fail "нова версія неповна" "" broken
fi
rm -rf "$BACKUP" 2>/dev/null

finish_ok
