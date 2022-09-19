#!/bin/sh
# shellcheck shell=ash

normalize_zpool_devs() {
    fulls=$1
    last_components=$2
    echo "$fulls" | while read -r dev; do
        local last_comp=${dev##*/}
        if echo "$last_components" | grep -qx "$last_comp"; then
            echo "$dev"
        elif echo "$last_components" | grep -qx "${last_comp%1}"; then
            echo "${dev%1}"
        elif echo "$last_components" | grep -qx "${last_comp%-part1}"; then
            echo "${dev%-part1}"
        elif echo "$last_components" | grep -qx "${last_comp%p1}"; then
            echo "${dev%p1}"
        fi
    done
}

reset_vars() {
    local type=$1
    case $type in
    mirror)
        is_mirror=1
        is_raidz=0
        ;;
    raidz)
        is_raidz=$2
        is_mirror=0
        ;;
    esac
    disk_number=1
}

parse_vdevs() {
    local vdevs=$1
    local is_mirror=0
    local last_mirror_disk=""
    local is_raidz=0
    local disk_number=1
    detach_disks=""
    attach_disks=""
    vdev_spec=""
    offline_disks=""
    for dev in $vdevs; do
        case $dev in
        mirror-*)
            reset_vars mirror 1
            ;;
        raidz1-*)
            vdev_spec="$vdev_spec raidz1"
            reset_vars raidz 1
            ;;
        raidz2-*)
            vdev_spec="$vdev_spec raidz2"
            reset_vars raidz 2
            ;;
        raidz3-*)
            vdev_spec="$vdev_spec raidz3"
            reset_vars raidz 3
            ;;
        *)
            if [ "$is_mirror" -eq 1 ]; then
                if [ "$disk_number" -eq 1 ]; then
                    vdev_spec="$vdev_spec $dev"
                    last_mirror_disk="$dev"
                else
                    detach_disks="$detach_disks $dev"
                    attach_disks=$(printf "%s\n" "$attach_disks" "$last_mirror_disk $dev")
                fi
            elif [ "$is_raidz" -ge 1 ]; then
                if [ "$disk_number" -le "$is_raidz" ]; then
                    offline_disks="$offline_disks $dev"
                    vdev_spec="$vdev_spec %s"
                else
                    vdev_spec="$vdev_spec $dev"
                fi
            fi
            disk_number=$((disk_number + 1))
            ;;
        esac
    done
}

zpool_get() {
    local pool=$1
    local property=$2
    zpool get -H -p -o value "$property" "$pool"
}

zfs_get() {
    local zfs=$1
    local property=$2
    zfs get -H -p -o value "$property" "$zfs"
}

zpool_detach() {
    local pool=$1
    shift
    for disk in "$@"; do
        zpool detach "$pool" "$disk"
    done
}

zpool_fault_disks() {
    local pool=$1
    shift
    zpool offline -f "$pool" "$@"
}

zpool_create() {
    local pool=$1
    local ashift=$2
    shift 2
    zpool create -o ashift="$ashift" "$pool" "$@"
}

zpool_create_from_faulted() {
    local from_pool=$1
    local pool=$2
    local ashift=$3
    shift 3
    zpool_fault_disks "$from_pool" "$@"
    zpool export "$from_pool"
    zpool_create "$pool" "$ashift" -f "$@"
    zpool import -N "$from_pool"
}

zpool_attach_disks() {
    local pool=$1
    local ashift=$2
    local attaches=$3
    echo "$attaches" | sed -e '/^$/d' | while read -r attach; do
        # shellcheck disable=SC2086
        zpool attach -o ashift="$ashift" "$pool" $attach
    done
}

zpool_replace() {
    local pool=$1
    local ashift=$2
    local replaces=$3
    echo "$replaces" | sed -e '/^$/d' | while read -r replace; do
        # shellcheck disable=SC2086
        zpool replace -o ashift="$ashift" "$pool" $replace
    done
}

zfs_replicate() {
    src=$1
    dest=$2
    snapshot_name=$3
    zfs snapshot -r "$src"@"$snapshot_name"
    zfs send -R "$src"@"$snapshot_name" | zfs receive "$dest" -F -u
}

zfs_receive_keep_encryption() {
    zfs receive -u -x encryption -x keyformat "$@"
}

zfs_send_all() {
    src=$1
    dest=$2
    snapshot_name=$3
    zfs list -H -o name -r -t filesystem,volume "$src" | tail -n +2 | while read -r fs; do
        first_snapshot=$(zfs list -H -o name -t snapshot "$fs" | head -n 1)
        if [ "$first_snapshot" = "$fs@$snapshot_name" ]; then
            zfs send -p "$fs@$snapshot_name" | zfs_receive_keep_encryption -d "$dest"
        else
            zfs send -p "$first_snapshot" | zfs_receive_keep_encryption -d "$dest"
            zfs send -p -I "$first_snapshot" "$fs@$snapshot_name" | zfs_receive_keep_encryption -d "$dest"
        fi
    done
}

zpool_create_encrypted() {
    local password=$1
    shift
    printf "%s\n%s\n" "$password" "$password" | zpool_create "$@" -O encryption=on -O keyformat=passphrase
}

zpool_get_local() {
    pool=$1
    zpool get all -H -p -o property,value,source "$pool" |
        awk '$1 !~ /^feature@/ && $1 != "ashift" && $3 == "local" { print $1"="$2 }'
}

zfs_get_local() {
    zfs=$1
    zfs get all -H -p -o property,value -s local,received "$zfs" | sed -e "s/\t/=/"
}

main() {
    local pool_name=$1
    local passphrase=$2

    if [ "${#passphrase}" -lt 8 ]; then
        echo "Passphrase too short (min 8)." >&2
        exit 1
    fi

    local temp_pool_name=encrypt_rpool
    local temp_snapshot=encrypt_rpool
    local temp_zvol_store=encrypt_rpool

    modprobe zfs
    zpool import -N "$pool_name"

    if [ "$(zpool_get "$pool_name" health)" != "ONLINE" ]; then
        echo "The pool's health is not ONLINE" >&2
        exit 1
    fi

    if [ "$(zfs_get "$pool_name" encryptionroot)" != "-" ]; then
        echo "Pool already encrypted."
        # Try to load key
        echo "$passphrase" | zfs load-key "$pool_name" || :
        exit
    fi

    local zpool_devs
    zpool_devs_full=$(zpool list -v -P -H "$pool_name" | tail -n +2 | cut -f 2)
    zpool_devs_last_comp=$(zpool list -v -H "$pool_name" | tail -n +2 | cut -f 2)
    zpool_devs=$(normalize_zpool_devs "$zpool_devs_full" "$zpool_devs_last_comp")
    local ashift
    ashift=$(zpool_get "$pool_name" ashift)

    parse_vdevs "$zpool_devs"

    local virtual_disks=""
    local replace_disks=""
    if [ "$detach_disks" ]; then
        # shellcheck disable=SC2086
        zpool_detach "$pool_name" $detach_disks
        # shellcheck disable=SC2086
        zpool_create "$temp_pool_name" "$ashift" $detach_disks
    elif [ "$offline_disks" ]; then
        # shellcheck disable=SC2086
        zpool_create_from_faulted "$pool_name" "$temp_pool_name" "$ashift" $offline_disks
        for disk in $offline_disks; do
            local temp_disk="$temp_pool_name/$temp_zvol_store$disk"
            zfs create -p -s -V "$(blockdev --getsize64 "$disk")" "$temp_disk"
            virtual_disks="$virtual_disks /dev/zvol/$temp_disk"
            replace_disks=$(printf "%s\n" "$replace_disks" "/dev/zvol/$temp_disk $disk")
        done
        # shellcheck disable=SC2086,SC2059
        vdev_spec=$(printf "$vdev_spec\n" $virtual_disks)
    else
        echo "Only mirrors and raidz are supported." >&2
        exit 1
    fi

    if [ "$(zpool_get "$temp_pool_name" free)" -gt "$(zpool_get "$pool_name" allocated)" ]; then
        zfs_replicate "$pool_name" "$temp_pool_name" $temp_snapshot

        local zpool_props
        zpool_props=$(zpool_get_local "$pool_name")
        local zfs_props
        zfs_props=$(zfs_get_local "$pool_name")

        zpool destroy "$pool_name"
        # shellcheck disable=SC2086
        zpool_create_encrypted "$passphrase" "$pool_name" "$ashift" $vdev_spec
        if [ "$offline_disks" ] && [ -z "$detach_disks" ]; then
            # shellcheck disable=SC2086
            zpool offline -f "$pool_name" $virtual_disks
            zfs destroy -r "$temp_pool_name/$temp_zvol_store"
        fi
        zfs_send_all "$temp_pool_name" "$pool_name" "$temp_snapshot"
        zfs destroy -r "$pool_name@$temp_snapshot"

        # Restore properties
        for key_value in $zpool_props; do
            zpool set "$key_value" "$pool_name"
        done
        # shellcheck disable=SC2086
        [ "$zfs_props" ] && zfs set $zfs_props "$pool_name"
    else
        echo "Not enough space on redundant disks" >&2
    fi

    # Restore redundancy
    zpool destroy "$temp_pool_name"
    zpool_attach_disks "$pool_name" "$ashift" "$attach_disks"
    if [ -z "$detach_disks" ]; then
        # shellcheck disable=SC2086
        zpool_replace "$pool_name" "$ashift" "$replace_disks"
    fi
}

resume_initramfs() {
    local pool_name=$1
    if zpool get -H -o value name 2>/dev/null | grep -Fxq "$pool_name"; then
        # Leave a pool imported. ZFS `mountroot` script sets `POOL_IMPORTED` value
        # after importing a pool. But if it's already imported, value is not set,
        # causing an extra shell to appear.
        # ZFS script is sourcing this file at the start. Add `POOL_IMPORTED` to it.
        echo POOL_IMPORTED=1 >>/etc/default/zfs
    fi
    # In order to continue boot process, we need to close main shell.
    # Shell would not close with regular signals. Send SIGHUP to it.
    # shellcheck disable=SC2009
    console_shell=$(ps -o pid,args | grep "[s]h -i" | awk 'FNR==1 { print $1 }')
    kill -1 "$console_shell"
}

if [ ! "$_TEST" ]; then
    set -euxo pipefail

    # Make zfs commands available
    PATH=/usr/sbin:$PATH

    # Continue boot process in case of errors
    # shellcheck disable=SC2064
    trap "resume_initramfs $1" EXIT

    main "$@"
fi
