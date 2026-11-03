#!/bin/bash
# Starts a release AppImage on stock distributions in podman, the way people run it: as a normal user,
# mounted through FUSE (no APPIMAGE_EXTRACT_AND_RUN), with only the distribution's own packages and no libfuse2.
#   tools/release/check_appimage.sh <AppImage> [distro...]      (default: all below)
# For each distro the app starts headless and quits; every native addon must load, except the PipeWire output
# where the distribution's PipeWire is older than 1.4 (Ubuntu 24.04, Fedora 39). Fedora 39 is also the oldest
# glibc (2.38) the README promises.
# The AppImage runtime is static: what it needs from the system is fusermount3 (the fuse3 package).
set -euo pipefail
APPIMAGE=$(realpath "${1:?usage: check_appimage.sh <AppImage> [distro...]}")
shift
DISTROS=("$@")
[ ${#DISTROS[@]} -gt 0 ] || DISTROS=(ubuntu-24.04 fedora-39 arch tumbleweed)
LOG_DIR=$(dirname "$APPIMAGE")

# image | packages command | does its PipeWire reach 1.4
spec() {
	case "$1" in
		ubuntu-24.04) echo "docker.io/library/ubuntu:24.04|apt-get update -qq && apt-get install -y -qq --no-install-recommends fuse3 libpipewire-0.3-0t64 libvulkan1 libgbm1 libinput10 libfontconfig1|old" ;;
		fedora-39) echo "docker.io/library/fedora:39|dnf install -y -q fuse3 pipewire-libs vulkan-loader mesa-libgbm libinput fontconfig shadow-utils util-linux|old" ;;
		arch) echo "docker.io/library/archlinux:latest|pacman -Sy --noconfirm --needed fuse3 pipewire vulkan-icd-loader mesa libinput fontconfig|new" ;;
		tumbleweed) echo "registry.opensuse.org/opensuse/tumbleweed:latest|zypper -n -q in --no-recommends fuse3 libpipewire-0_3-0 libvulkan1 libgbm1 libinput10 fontconfig shadow util-linux|new" ;;
		*) echo "unknown distro $1" >&2; return 1 ;;
	esac
}

status=0
for d in "${DISTROS[@]}"; do
	IFS='|' read -r image install pipewire <<< "$(spec "$d")"
	log=$LOG_DIR/check-$d.log
	podman run --rm --device /dev/fuse --cap-add SYS_ADMIN -v "$APPIMAGE:/app.AppImage:ro" "$image" sh -c "
		($install) > /dev/null 2>&1 || { echo 'package install failed'; exit 1; }
		useradd -m tester
		echo \"glibc \$(ldd --version | head -1 | grep -o '[0-9.]*\$')\"
		su tester -c 'cd /tmp && /app.AppImage --headless --quit 2>&1'" > "$log" 2>&1 || true
	glibc=$(grep -o '^glibc [0-9.]*' "$log" | cut -d' ' -f2 || true)
	# Godot prints its banner once the AppImage is mounted and the engine runs
	if ! grep -q '^Godot Engine v' "$log"; then
		echo "$d (glibc ${glibc:-?}): the app did not start, see $log"; status=1; continue
	fi
	failed=$(grep -o "Error loading extension: 'res://addons/[a-z_]*" "$log" | sed 's#.*res://##' | sort -u | tr "\n" " " || true)
	expected=""
	[ "$pipewire" = old ] && expected="addons/yorishiro_pipewire "
	if [ "$failed" = "$expected" ]; then
		echo "$d (glibc ${glibc:-?}): ok${expected:+, PipeWire output off as expected (PipeWire older than 1.4)}"
	else
		echo "$d (glibc ${glibc:-?}): addons that did not load: ${failed:-none}, expected: ${expected:-none}; see $log"
		status=1
	fi
done
exit $status
