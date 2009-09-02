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
mkvmtemplate - a tool for creating a template from a running vm
Usage:
    $(basename $0) [options] src_vm template_name

Summary:
    Creates a tar file to act as a template from a Xen VM snapshot.
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
    dest_tar="$2.tgz";
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

## Snapshot and mount source LV
mkdir /mnt/${src_vm}snap 2>/dev/null || true;
step "Made mount point /mnt/${src_vm}";
exit_stack_push "lvremove -f /dev/SysVolGroup/${src_vm}snap";
lvcreate -s -L 2G -n ${src_vm}snap /dev/SysVolGroup/${src_vm};
step "Created LV ${src_vm}snap";
mount /dev/SysVolGroup/${src_vm}snap /mnt/${src_vm}snap/;
step "Mounted LV";

## Create a tarball from the snapshot
echo "Tarring..."
tar --exclude='*.log' --exclude='*var/log/*_log*' -czf $dest_tar -C /mnt/${src_vm}snap/ .
## Sync the LVs and release the snapshot
step "Tarred";
umount /mnt/${src_vm}snap/;
step "Unmounted /mnt/${src_vm}snap/";
lvremove -f /dev/SysVolGroup/${src_vm}snap;
exit_stack_pop;
step "Removed snapshot LV";

