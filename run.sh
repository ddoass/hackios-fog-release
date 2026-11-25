#!/bin/bash
# Run the prebuilt SpringBoard payload on the Xiaomi Redmi 10C (fog).
# SECS sets how long to collect logs; the prebuilt kernel's timer is fixed at 2400 s.
# SLICE controls how often to collect a log. The resident image is uploaded into RAM.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd -- "$ROOT" || exit 1

UEFI=$ROOT/prebuilt/xnu-usb-fog.img
PAYLOAD=$ROOT/prebuilt/run-sb-unblock.bin
FLASHBOOT=$ROOT/prebuilt/flashboot.apfs
XL=$ROOT/prebuilt/xl

SECS=${SECS:-2400}
SLICE=${SLICE:-120}
OUT=${OUT:-$ROOT/logs/run-sb-unblock.log}
PHONE=${XDG_RUNTIME_DIR:-/tmp}/darwin-hakios-phone

say() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { say "$*" >&2; exit 1; }

for value in "$SECS" "$SLICE"; do
	[[ $value =~ ^[0-9]{1,9}$ ]] && ((10#$value > 0)) ||
		fail "SECS and SLICE must be positive integer seconds (up to 9 digits)"
done
SECS=$((10#$SECS))
SLICE=$((10#$SLICE))

for file in "$UEFI" "$PAYLOAD" "$FLASHBOOT"; do
	[[ -s $file && -r $file ]] || fail "missing, empty or unreadable image: $file"
done
[[ -x $XL ]] || fail "missing or non-executable helper: $XL"

for command in fastboot flock timeout python3; do
	command -v "$command" >/dev/null || fail "required command not found: $command"
done
mkdir -p -- "$ROOT/logs" || fail "cannot create $ROOT/logs"
[[ ! -d $OUT ]] || fail "OUT is a directory: $OUT"
snapshot_dir=$(mktemp -d -- "$OUT.tmp.XXXXXX") || fail "cannot create a temporary directory for $OUT"
snapshot=$snapshot_dir/kernel.log
trap 'rm -f -- "$snapshot"; rmdir -- "$snapshot_dir"' EXIT

exec 9>"$PHONE.launch" || fail "cannot open the launcher lock"
flock -n 9 || fail "another launch is in progress"

read_state() {
	local output
	output=$("$XL" state --serial) || fail "could not identify a single Fastboot device"
	read -r state serial product <<< "$output"
}

wait_for_stock() {
	local deadline=$((SECONDS + 240)) adb_state
	local rebooted=0
	while ((SECONDS < deadline)); do
		read_state
		[[ $state == fastboot ]] && return 0
		if [[ $state == absent ]] && ((rebooted == 0)) && command -v adb >/dev/null; then
			adb_state=$(timeout 5 adb -d get-state 9>&- 2>/dev/null) || adb_state=
			case "$adb_state" in
				device|recovery)
					say "requesting the bootloader over ADB"
					timeout 20 adb -d reboot bootloader 9>&- || fail "ADB reboot to bootloader failed"
					rebooted=1
					;;
			esac
		fi
		sleep 2
	done
	return 1
}

read_state
if [[ $state == loader ]]; then
	say "leaving the previous loader session"
	flock -w 30 "$PHONE.lock" timeout 20 fastboot -s "$serial" reboot || fail "loader reboot failed"
fi
if [[ $state != fastboot ]]; then
	say "waiting for the phone's bootloader"
	wait_for_stock || fail "the phone did not reach Fastboot"
fi
[[ $product == fog ]] || fail "expected stock Fastboot product fog, got ${product:-unknown}"

say "booting the UEFI"
flock -w 30 "$PHONE.lock" timeout 45 fastboot -s "$serial" boot "$UEFI" ||
	fail "UEFI boot failed"

deadline=$((SECONDS + 120))
while :; do
	read_state
	[[ $state == loader ]] && break
	((SECONDS < deadline)) || fail "xnuloader did not appear within 120 s"
	sleep 2
done

say "uploading the resident image"
XL_FASTBOOT_SERIAL=$serial "$XL" ramdisk "$FLASHBOOT" || fail "resident image upload failed"

say "staging and starting the payload"
(
	flock -w 30 8 || exit 1
	timeout 120 fastboot -s "$serial" stage "$PAYLOAD" || exit 1
	timeout 30 fastboot -s "$serial" oem run
) 8>"$PHONE.lock" || fail "payload launch failed"

say "collecting logs for $SECS s"
started=$SECONDS
i=0
saved=0
while ((SECONDS - started < SECS)); do
	remaining=$((SECS - (SECONDS - started)))
	delay=$SLICE
	((delay <= remaining)) || delay=$remaining
	sleep "$delay" || fail "log collection interrupted"
	i=$((i + 1))
	if XL_FASTBOOT_SERIAL=$serial "$XL" log | sed -n '/== KERNEL LOG/,$p' > "$snapshot" && [[ -s $snapshot ]]; then
		mv -fT -- "$snapshot" "$OUT" || fail "cannot update $OUT"
		saved=1
		say "slice $i: $(wc -c < "$OUT") bytes, $(grep -ac 'hakios: threads' "$OUT") thread dumps, last line: $(tail -n 1 "$OUT" | cut -c1-60)"
	else
		say "slice $i: no kernel log received" >&2
	fi
	if ((i % 2 == 0)); then
		XL_FASTBOOT_SERIAL=$serial "$XL" screenshot "$ROOT/logs/screen-$((SECONDS - started)).png" ||
			say "slice $i: screenshot failed" >&2
	fi
done
((saved)) || fail "no kernel log collected during this run"
say "kernel log saved to $OUT"
