#!/bin/bash
# Install a built Procursus + Sileo + ElleKit prefix into the SWEET HFS+ root.
#
#   sudo tools/sapphire-jb-install.sh IMG JB_PREFIX OUTDIR [hfsplus.ko]
#
# JB_PREFIX is the extracted directory containing usr/, Applications/, prep.sh,
# e.g. ~/sapphire-jb-build-current/root/var/jb. No phone metadata is needed:
# this operates on the complete raw root image on the build host.
set -euo pipefail

[[ $# -ge 3 && $# -le 4 ]] || {
  echo "usage: sudo $0 IMG JB_PREFIX OUTDIR [hfsplus.ko]" >&2
  exit 2
}
[[ $EUID == 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

img=$(realpath "$1")
prefix=$(realpath "$2")
out=$(realpath -m "$3")
ko=${4:-}
mnt=/mnt/ios

[[ -f "$img" ]] || { echo "root image not found: $img" >&2; exit 1; }
[[ -x "$prefix/usr/bin/dpkg" ]] || { echo "not a Procursus prefix: $prefix" >&2; exit 1; }
[[ -x "$prefix/prep.sh" ]] || { echo "missing executable prep.sh in $prefix" >&2; exit 1; }
[[ -d "$prefix/Applications/Sileo.app" ]] || { echo "missing Sileo.app in $prefix" >&2; exit 1; }
# TweakLoader.dylib is intentionally an absolute /var/jb symlink in the Procursus
# staging tree, so test its in-prefix target rather than following it on the build host.
[[ -f "$prefix/usr/lib/ellekit/libinjector.dylib" ]] || {
  echo "missing ElleKit injector: usr/lib/ellekit/libinjector.dylib" >&2
  exit 1
}
if [[ -L "$prefix/usr/lib/TweakLoader.dylib" ]]; then
  [[ "$(readlink "$prefix/usr/lib/TweakLoader.dylib")" == "/var/jb/usr/lib/ellekit/libinjector.dylib" ]] || {
    echo "unexpected TweakLoader.dylib link target" >&2
    exit 1
  }
elif [[ ! -f "$prefix/usr/lib/TweakLoader.dylib" ]]; then
  echo "missing ElleKit TweakLoader.dylib" >&2
  exit 1
fi
[[ -x "$prefix/usr/sbin/sysctl" ]] || { echo "missing Procursus sysctl" >&2; exit 1; }
[[ -x "$prefix/bin/sh" ]] || { echo "missing Procursus /bin/sh" >&2; exit 1; }
[[ -f "$prefix/usr/lib/TweakInject/PreferenceLoader.dylib" ]] || {
  echo "missing PreferenceLoader in TweakInject" >&2
  exit 1
}
for name in chmod cp mkdir mv rm; do
  [[ -x "$prefix/usr/bin/$name" ]] || { echo "missing Procursus command: $name" >&2; exit 1; }
done

mkdir -p "$out" "$mnt"
mountpoint -q "$mnt" && { echo "$mnt is already mounted; refusing" >&2; exit 1; }
if ! grep -qw hfsplus /proc/filesystems; then
  [[ -n "$ko" && -f "$ko" ]] || { echo "HFS+ unavailable; pass the matching hfsplus.ko as argument 4" >&2; exit 1; }
  insmod "$ko"
fi

trap 'mountpoint -q "$mnt" && umount "$mnt"' EXIT
fsck.hfsplus -fy "$img"
mount -t hfsplus -o loop,force "$img" "$mnt"

[[ -d "$mnt/private/var" && -d "$mnt/Applications" && -d "$mnt/bin" ]] || {
  echo "image is missing expected iOS directories" >&2
  exit 1
}
[[ -f "$mnt/System/Library/xpc/launchd.plist" ]] || {
  echo "launchd cache not found" >&2
  exit 1
}

# Install the complete prefix at the persistent /var location used by this port.
rm -rf "$mnt/private/var/jb"
cp -a "$prefix" "$mnt/private/var/jb"
jb="$mnt/private/var/jb"

# The mobile-owned package-manager state must be writable by Sileo.
for d in var/mobile var/mobile/Library var/mobile/Library/Caches \
         var/mobile/Library/Preferences var/mobile/Documents \
         var/lib/apt/sileolists var/lib/apt/sileolists/partial var/log; do
  mkdir -p "$jb/$d"
done
chown -R 501:501 "$jb/var/mobile"
chown 501:501 "$jb/var/lib/apt/sileolists" "$jb/var/lib/apt/sileolists/partial"

# LaunchServices discovers applications from /Applications, not the rootless prefix.
for app in "$jb"/Applications/*.app; do
  [[ -d "$app" ]] || continue
  name=${app##*/}
  rm -rf "$mnt/Applications/$name"
  cp -a "$app" "$mnt/Applications/$name"
  chown -R 0:0 "$mnt/Applications/$name"
done
[[ -f "$mnt/Applications/Sileo.app/giveMeRoot" ]] || {
  echo "Sileo giveMeRoot helper was not installed" >&2
  exit 1
}
chown 0:0 "$mnt/Applications/Sileo.app/giveMeRoot"
chmod 4755 "$mnt/Applications/Sileo.app/giveMeRoot"

# iOS does not ship these shell entry points; Sileo and rootless scripts expect them.
for name in sh bash; do
  if [[ ! -e "$mnt/bin/$name" && ! -L "$mnt/bin/$name" ]]; then
    ln -s "/var/jb/bin/$name" "$mnt/bin/$name"
  fi
done
# Sileo's root helper invokes these by their traditional absolute /bin paths.
# Keep any native iOS implementation; otherwise install a real copy, not a symlink.
for name in chmod cp mkdir mv rm; do
  if [[ -e "$mnt/bin/$name" && ! -L "$mnt/bin/$name" ]]; then
    continue
  fi
  rm -f "$mnt/bin/$name"
  cp -p "$jb/usr/bin/$name" "$mnt/bin/$name"
  chown 0:0 "$mnt/bin/$name"
  chmod 755 "$mnt/bin/$name"
done

# Remove stale LaunchServices databases so the copied applications are discovered on boot.
find "$mnt/private/var/mobile/Containers/Data/InternalDaemon" \
  -path '*/Library/Caches/*com.apple.LaunchServices-*.csstore' -type f -delete 2>/dev/null || true

# Add both startup jobs to launchd's system cache. /var/jb/Library/LaunchDaemons
# alone is not scanned by this port's launchd setup.
lp="$mnt/System/Library/xpc/launchd.plist"
cp -a "$lp" "$lp.new"
python3 -I - "$lp.new" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    raw = f.read()
fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist00') else plistlib.FMT_XML
p = plistlib.loads(raw)
jobs = p.get('LaunchDaemons')
if not isinstance(jobs, dict):
    raise SystemExit('launchd.plist has no LaunchDaemons dictionary')

system = '/System/Library/LaunchDaemons/'
jobs[system + 'com.sapphire.glload.plist'] = {
    'Label': 'com.sapphire.glload',
    'ProgramArguments': [
        '/var/jb/bin/sh', '-c',
        '[ -f /redwood/lib/libredwood-glload.dylib ] && /var/jb/usr/sbin/sysctl -w kern.sweet_glload=1'
    ],
    'RunAtLoad': True,
    'LaunchOnlyOnce': True,
    'UserName': 'root',
    'POSIXSpawnType': 'Interactive',
    'StandardOutPath': '/var/jb/var/log/glload.log',
    'StandardErrorPath': '/var/jb/var/log/glload.log',
}
jobs[system + 'com.sapphire.jbprep.plist'] = {
    'Label': 'com.sapphire.jbprep',
    'ProgramArguments': ['/var/jb/bin/sh', '/var/jb/prep.sh'],
    'RunAtLoad': True,
    'LaunchOnlyOnce': True,
    'UserName': 'root',
    'POSIXSpawnType': 'Interactive',
    'StandardOutPath': '/var/jb/var/log/prep.log',
    'StandardErrorPath': '/var/jb/var/log/prep.log',
}
with open(path, 'wb') as f:
    plistlib.dump(p, f, fmt=fmt, sort_keys=False)
check = plistlib.load(open(path, 'rb'))
for label in ('com.sapphire.glload', 'com.sapphire.jbprep'):
    matches = [v for v in check['LaunchDaemons'].values() if v.get('Label') == label]
    assert len(matches) == 1, (label, len(matches))
print('launchd.plist:', len(check['LaunchDaemons']), 'jobs; glload + jbprep verified')
PY
chown --reference="$lp" "$lp.new"
chmod --reference="$lp" "$lp.new"
mv "$lp.new" "$lp"

# Verify the installed tree and the launchd entries before touching the image again.
test -x "$jb/prep.sh"
test -f "$jb/usr/lib/ellekit/libinjector.dylib"
test -L "$jb/usr/lib/TweakLoader.dylib" || test -f "$jb/usr/lib/TweakLoader.dylib"
test -f "$jb/Library/MobileSubstrate/DynamicLibraries" || \
  test -L "$jb/Library/MobileSubstrate/DynamicLibraries"
test -f "$mnt/redwood/lib/libredwood-glload.dylib"
python3 -I - "$lp" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
jobs = p['LaunchDaemons']
for label in ('com.sapphire.glload', 'com.sapphire.jbprep'):
    matches = [v for v in jobs.values() if v.get('Label') == label]
    assert len(matches) == 1
    print(label, '->', matches[0]['ProgramArguments'])
PY

sync
du -sh "$jb"
umount "$mnt"
trap - EXIT
fsck.hfsplus -fy "$img"
echo "Sileo + Procursus + ElleKit startup integration installed."
