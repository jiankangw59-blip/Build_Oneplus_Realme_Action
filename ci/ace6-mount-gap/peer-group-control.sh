#!/bin/sh
set -eu
export LC_ALL=C

work=$(mktemp -d /tmp/peer-group-control.XXXXXX)
cleanup_work() {
    rm -f "$work/parent-before" "$work/parent-during" "$work/parent-after"
    if [ -d "$work/mounts" ]; then
        rmdir "$work/mounts"
    fi
    rmdir "$work"
}
trap cleanup_work EXIT

parent_ns=$(readlink /proc/self/ns/mnt)
cat /proc/self/mountinfo > "$work/parent-before"
printf 'Linux %s; parent namespace %s; effective UID %s\n' \
    "$(uname -r)" "$parent_ns" "$(id -u)"

status=0
unshare --mount --propagation private -- sh -eu -s -- "$work" "$$" "$parent_ns" <<'CHILD' || status=$?
work=$1
parent_pid=$2
parent_ns=$3
child_ns=$(readlink /proc/self/ns/mnt)
test "$child_ns" != "$parent_ns"
awk '
    {
        for (i = 7; i <= NF && $i != "-"; i++) {
            if ($i ~ /^(shared|master|propagate_from):/)
                inherited_propagation = 1
        }
    }
    END { exit inherited_propagation || NR == 0 }
' /proc/self/mountinfo
printf 'Child namespace %s has no inherited shared/master propagation\n' "$child_ns"

fixture="$work/mounts"
mkdir "$fixture"
mounted=0
cleanup_mounts() {
    if [ "$mounted" = 1 ]; then
        umount --recursive "$fixture"
    fi
    awk -v path="$fixture" '
        $5 == path || index($5, path "/") == 1 { leftovers = 1 }
        END { exit leftovers }
    ' /proc/self/mountinfo
    rmdir "$fixture"
}
trap cleanup_mounts EXIT

group_at() {
    awk -v path="$1" '$5 == path {
        for (i = 7; i <= NF && $i != "-"; i++) {
            if ($i ~ /^shared:[0-9]+$/) {
                print substr($i, 8)
                exit
            }
        }
    }' /proc/self/mountinfo
}

mount_absent() {
    awk -v path="$1" '
        $5 == path { present = 1 }
        END { exit present || NR == 0 }
    ' /proc/self/mountinfo
}

snapshot() {
    printf '\n%s\n' "$1"
    awk -v path="$fixture" '$5 == path || index($5, path "/") == 1' /proc/self/mountinfo
}

inconclusive() {
    printf 'INCONCLUSIVE: %s\n' "$*" >&2
    exit 78
}

mount -t tmpfs -o size=64k none "$fixture"
mounted=1
mount --make-shared "$fixture"
parent_group=$(group_at "$fixture")
test -n "$parent_group"

set --
for n in 1 2 3 4 5; do
    mkdir "$fixture/mount$n" "$fixture/bind$n"
    mount -t tmpfs -o size=64k none "$fixture/mount$n"
    mkdir "$fixture/mount$n/subdir"
    mount --bind "$fixture/mount$n/subdir" "$fixture/bind$n"
    group=$(group_at "$fixture/mount$n")
    test -n "$group"
    test "$group" = "$(group_at "$fixture/bind$n")"
    set -- "$@" "$group"
done
snapshot 'BEFORE: five source and bind pairs'
cat "/proc/$parent_pid/mountinfo" > "$work/parent-during"

if [ "$1" -ne "$((parent_group + 1))" ] || [ "$2" -ne "$(($1 + 1))" ] ||
   [ "$3" -ne "$(($1 + 2))" ] || [ "$4" -ne "$(($1 + 3))" ] ||
   [ "$5" -ne "$(($1 + 4))" ]; then
    inconclusive "the allocator did not return consecutive parent and child IDs: $parent_group $*"
fi
if [ "$parent_group" -le 0 ] || [ "$5" -ge 200000 ]; then
    inconclusive "the fixture did not receive low peer-group IDs: $parent_group $*"
fi

umount "$fixture/bind1"
test "$1" = "$(group_at "$fixture/mount1")"
mount_absent "$fixture/bind1"
mkdir "$fixture/with-peer-held"
mount -t tmpfs -o size=64k none "$fixture/with-peer-held"
held_group=$(group_at "$fixture/with-peer-held")
test -n "$held_group"
test "$held_group" != "$1"
snapshot 'ONE PEER LEFT: original group remains assigned, new mount has a different group'
if [ "$held_group" -le "$5" ]; then
    inconclusive "allocator returned $held_group while the initial groups were held"
fi
umount "$fixture/with-peer-held"

umount "$fixture/mount1"
umount "$fixture/bind4"
test "$4" = "$(group_at "$fixture/mount4")"
umount "$fixture/mount4"
for n in 1 4; do
    mount_absent "$fixture/mount$n"
    mount_absent "$fixture/bind$n"
done
test "$2" = "$(group_at "$fixture/mount2")"
test "$3" = "$(group_at "$fixture/mount3")"
test "$5" = "$(group_at "$fixture/mount5")"
snapshot 'AFTER: group gaps following removal of both peers in pairs 1 and 4'
printf 'Removed groups %s and %s; retained fixture groups %s,%s,%s,%s\n' \
    "$1" "$4" "$parent_group" "$2" "$3" "$5"

mkdir "$fixture/reuse1" "$fixture/reuse4"
mount -t tmpfs -o size=64k none "$fixture/reuse1"
mount -t tmpfs -o size=64k none "$fixture/reuse4"
reuse1=$(group_at "$fixture/reuse1")
reuse4=$(group_at "$fixture/reuse4")
snapshot 'REUSE: independent tmpfs mounts after both peer groups were removed'
if [ "$reuse1" != "$1" ] || [ "$reuse4" != "$4" ]; then
    inconclusive "expected exact reuse of $1 and $4; observed $reuse1 and $reuse4"
fi

cleanup_mounts
trap - EXIT
printf 'Child fixture detached and removed\n'
CHILD

test "$(readlink /proc/self/ns/mnt)" = "$parent_ns"
cat /proc/self/mountinfo > "$work/parent-after"
cmp "$work/parent-before" "$work/parent-after"
if [ -f "$work/parent-during" ]; then
    cmp "$work/parent-before" "$work/parent-during"
fi
if [ "$status" -ne 0 ]; then
    exit "$status"
fi
test -f "$work/parent-during"
test ! -e "$work/mounts"
printf 'Original namespace mountinfo is byte-for-byte identical before, during and after\n'
sha256sum "$work/parent-before" "$work/parent-during" "$work/parent-after"
printf 'PEER_GROUP_CONTROL_PASSED\n'
