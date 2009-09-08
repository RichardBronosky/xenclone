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

mkdirsafe() {
    if mkdir $1 2>/dev/null; then
        echo make passed;
        exit_stack_push "rm -rf $1";
    else
        echo make failed;
        stat -f ' ' $1/* 1>/dev/null 2>&1 || exit_stack_push "rm -rf $1";
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
    vm1=$1;
    vm2=$2;
    if [[ $# -lt 3 ]]; then
        dest_lv_size=$(lvdisplay /dev/SysVolGroup/${vm1} | sed '/LV Size/!d;s/.*   *//;s/ //');
    else
        dest_lv_size=$3;
    fi
fi

## Test for root
if [[ $(id -nu) != 'root' ]]; then
    echo "This script must be run as root (or sudo)!";
    exit 1;
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
mkdirsafe /mnt/${vm2};
step "Made mount point /mnt/${vm2}";
lvcreate -n ${vm2} -L ${dest_lv_size} /dev/SysVolGroup;
step "Created LV ${vm2}";
mkfs -t ext3 /dev/SysVolGroup/${vm2};
step "Formated the LV ext3";
mount /dev/SysVolGroup/${vm2} /mnt/${vm2} || true;
step "Mounted LV";
lvcreate -n ${vm2}swap -L 1g /dev/SysVolGroup;
step "Created LV ${vm2}swap";
mkswap -L ${vm2}swap /dev/SysVolGroup/${vm2}swap;
step "Made LV a swap with mkswap";

## Snapshot and mount source LV
mkdirsafe /mnt/${vm1}snap;
step "Made mount point /mnt/${vm1}snap";
exit_stack_push "lvremove -f /dev/SysVolGroup/${vm1}snap";
lvcreate -s -L 2G -n ${vm1}snap /dev/SysVolGroup/${vm1};
step "Created LV ${vm1}snap";
exit_stack_push "umount /mnt/${vm1}snap/"
mount /dev/SysVolGroup/${vm1}snap /mnt/${vm1}snap/;
step "Mounted LV";

## Sync the LVs and release the snapshot
echo "Rsyncing...";
rsync -a --exclude '/var/log' --exclude '/var/www/html/*' /mnt/${vm1}snap/ /mnt/${vm2};
step "Rsynced";
umount /mnt/${vm1}snap/;
exit_stack_pop;
step "Unmounted /mnt/${vm1}snap/";
lvremove -f /dev/SysVolGroup/${vm1}snap;
exit_stack_pop;
step "Removed snapshot LV";

## Configure Xen and Linux
mkdirsafe /xen/${vm2};
step "Created /xen/${vm2}";
cp /xen/${vm1}/${vm1}.cfg /xen/${vm2}/${vm2}.cfg;
step "Copied source config to /xen/${vm2}/${vm2}.cfg";
ln -s /xen/${vm2}/${vm2}.cfg /etc/xen/${vm2};
step "Symlinked cfg to /etc/xen";
echo "Appending comments to configurations needing modification.";
echo -e "### Modify memory, maxmem, name, disk ###\n# :%s/${vm1}/${vm2}/gc" \
    >>/xen/${vm2}/${vm2}.cfg;
echo -e "### Modify HOSTNAME ###\n# :%s/${vm1}/${vm2}/gc" \
    >>/mnt/${vm2}/etc/sysconfig/network;
echo -e "### Modify IPADDR ###" \
    >>/mnt/${vm2}/etc/sysconfig/network-scripts/ifcfg-eth0;
echo -e "### Modify IPADDR ###" \
    >>/mnt/${vm2}/etc/sysconfig/network-scripts/ifcfg-eth1;
echo -e "### Modify self references ###\n# :%s/${vm1}/${vm2}/gc" \
    >>/mnt/${vm2}/etc/hosts;

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
${sudo}vim '+set hidden' /xen/${vm2}/${vm2}.cfg /mnt/${vm2}/etc/sysconfig/network /mnt/${vm2}/etc/sysconfig/network-scripts/ifcfg-eth0 /mnt/${vm2}/etc/sysconfig/network-scripts/ifcfg-eth1 /mnt/${vm2}/etc/hosts

After editing the files on the mounted LV, you must unmount it with:
${sudo}umount /mnt/${vm2}/
ECHO
