#!/usr/bin/env bash
export PATH=/sbin:/usr/sbin:$PATH

## TODO
## Smarter creation (and possibly cleanup) of mnt dirs.
## Smarter detection of log files (Ruby on Rails)
## Exclusion of excess (rollback) capistrano releases

## Exit on use of an uninitialized variable
set -o nounset
## Exit if any statement returns a non-true return value (non-zero).
set -o errexit

exit_stack_push(){
    exit_stack[${#exit_stack[*]}]=$*
}

exit_stack_pop(){
    unset exit_stack[$((${#exit_stack[*]}-1))]
}

do_exit_stack(){
    if [[ ${#exit_stack[*]} -gt 0 ]]; then
        for c in "${exit_stack[@]}"; do $c; done
    fi
}

## Every string in this array will be executed on exit.
exit_stack=();
trap do_exit_stack EXIT;

usage(){
    cat << ECHO
clone_vm - a tool for cloning a running vm
Usage:
    $(basename $0) [options] src_vm dest_vm [dest_lv_size]

Summary:
    Clones an LV based Xen VM via snapshot. Snapshot size is 2G. If
    dest_lv_size is ommitted, the size of the src_vm will be used. Files
    are copied via rsync, with html and logs excluded.
        -h      Display this information.
        -n      Do not pause after eash step.

    This script is highly biased to the author's needs. It should serve
    as a pretty good template. If you don't like it, you know where the
    vim $0 is.

Acknowledgments:
    Copyright (c) 2008 Richard Bronosky
    Offered under the terms of the MIT License.
    http://www.opensource.org/licenses/mit-license.php
    Created while employed by Atlanta Journal-Constitution
ECHO
}

## Test for root
if [[ $(id -nu) != 'root' ]]; then
    echo "This script must be run as root (or sudo)!";
    exit 1;
fi

## Test for arguments
if [[ $# -lt 2 ]]; then
    usage;
    exit 2;
else
    ## Parse command arguments
    while [[ $1 == -* ]]; do
        case "$1" in
            -h|--help|-\?) usage; exit 0;;
            -n) NOSTEP=1; shift;;
            --) shift; break;;
        esac
    done

    src_vm=$1;
    dest_vm=$2;
    if [[ $# -lt 3 ]]; then
        dest_lv_size=$(lvdisplay /dev/SysVolGroup/${src_vm} | sed '/LV Size/!d;s/.*   *//;s/ //');
    else
        dest_lv_size=$3;
    fi
fi

step(){
    echo $1;
    if [[ ${NOSTEP-X} = X ]]; then
        exit_stack_push 'stty echo';
        read -sn 1 -p "Press any key to continue...";
        echo;
        exit_stack_pop;
    fi
}

## Make and mount destination LV
mkdir /mnt/${dest_vm} 2>/dev/null || true;
step "Made mount point /mnt/${dest_vm}";
lvcreate -n ${dest_vm} -L ${dest_lv_size} /dev/SysVolGroup;
step "Created LV ${dest_vm}";
mkfs -t ext3 /dev/SysVolGroup/${dest_vm};
step "Formated the LV ext3";
mount /dev/SysVolGroup/${dest_vm} /mnt/${dest_vm} || true;
step "Mounted LV";
lvcreate -n ${dest_vm}swap -L 1g /dev/SysVolGroup;
step "Created LV ${dest_vm}swap";
mkswap -L ${dest_vm}swap /dev/SysVolGroup/${dest_vm}swap;
step "Made LV a swap with mkswap";

## Snapshot and mount source LV
mkdir /mnt/${src_vm}snap 2>/dev/null || true;
step "Made mount point /mnt/${src_vm}";
exit_stack_push "lvremove -f /dev/SysVolGroup/${src_vm}snap";
lvcreate -s -L 2G -n ${src_vm}snap /dev/SysVolGroup/${src_vm};
step "Created LV ${src_vm}";
mount /dev/SysVolGroup/${src_vm}snap /mnt/${src_vm}snap/;
step "Mounted LV";

## Sync the LVs and release the snapshot
echo "Rsyncing...";
rsync -a --exclude '/var/log' --exclude '/var/www/html/*' /mnt/${src_vm}snap/ /mnt/${dest_vm};
step "Rsynced";
umount /mnt/${src_vm}snap/;
step "Unmounted /mnt/${src_vm}snap/";
lvremove -f /dev/SysVolGroup/${src_vm}snap;
exit_stack_pop;
step "Removed snapshot LV";

## Configure Xen and Linux
mkdir /xen/${dest_vm};
step "Created /xen/${dest_vm}";
cp /xen/${src_vm}/${src_vm}.cfg /xen/${dest_vm}/${dest_vm}.cfg;
step "Copied source config to /xen/${dest_vm}/${dest_vm}.cfg";
ln -s /xen/${dest_vm}/${dest_vm}.cfg /etc/xen/${dest_vm};
step "Symlinked cfg to /etc/xen";
echo "Appending comments to configurations needing modification.";
echo -e "### Modify memory, maxmem, name, disk ###\n# :%s/${src_vm}/${dest_vm}/gc" \
    >>/xen/${dest_vm}/${dest_vm}.cfg;
echo -e "### Modify HOSTNAME ###\n# :%s/${src_vm}/${dest_vm}/gc" \
    >>/mnt/${dest_vm}/etc/sysconfig/network;
echo -e "### Modify IPADDR ###" \
    >>/mnt/${dest_vm}/etc/sysconfig/network-scripts/ifcfg-eth0;
echo -e "### Modify IPADDR ###" \
    >>/mnt/${dest_vm}/etc/sysconfig/network-scripts/ifcfg-eth1;
echo -e "### Modify self references ###\n# :%s/${src_vm}/${dest_vm}/gc" \
    >>/mnt/${dest_vm}/etc/hosts;

## Detect the use of sudo for command hints
if [[ ${SUDO_USER-X} = X ]]; then
    sudo='';
else
    sudo='sudo ';
fi

## Confirmation message
cat << ECHO

You need to modify the Xen cfg, hosts, network, and ifcfg files. Notes have been
appended to each of the files and they can all be opened with the following command:
${sudo}vim '+set hidden' /xen/${dest_vm}/${dest_vm}.cfg /mnt/${dest_vm}/etc/sysconfig/network /mnt/${dest_vm}/etc/sysconfig/network-scripts/ifcfg-eth0 /mnt/${dest_vm}/etc/sysconfig/network-scripts/ifcfg-eth1 /mnt/${dest_vm}/etc/hosts

After editing the files on the mounted LV, you must unmount it with:
${sudo}umount /mnt/${dest_vm}/
ECHO
