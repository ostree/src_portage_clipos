#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2017 ANSSI. All rights reserved.

# This file is set up as a dracut hook to mount the stateful part of the core
# (i.e., the part of the core filesystem which is read+write) as it is
# absolutely needed very early in the system boot sequence and cannot be
# delegated to the systemd unit/generator that processes `/etc/fstab` (because
# parts of systemd in the core require contents stored in /mnt/state, such as
# /etc/machine-id).
#
# Remark: This is one of the few (the only one at time of writing) mountpoints
# to be left to dracut (the initramfs infrastructure) and not fstab.
#
# WARNING: This mountpoint **MUST** be `rw` **AND** `nodev,nosuid,noexec`,
# otherwise the system-wide enforcement of W^X (see the security principles and
# architecture design in the CLIP OS documentation) would be broken.

readonly TMPFS="/tmp" # FIXME: create a transient tmpfs/ramfs to store stuff?

readonly PCR_BANK="sha256"
readonly PCRS_SETUP="${PCR_BANK}:0,2,7"
readonly PCRS_ALL="${PCR_BANK}:0,1,2,3,5,6,7"

readonly POLICY_DIGEST="${TMPFS}/policy.digest"
readonly OBJECT_CONTEXT="${TMPFS}/object.context"

readonly PRIMARY_HANDLE="0x81000000"

readonly KEYFILE_SIZE=128
KEYFILE=""

readonly VG_NAME='@VG_NAME@'
readonly REQUIRE_TPM='@REQUIRE_TPM@'
readonly BRUTEFORCE_LOCKOUT='@BRUTEFORCE_LOCKOUT@'

main() {
	export TPM2TOOLS_TCTI="device:/dev/tpmrm0"

	# If no TPM 2.0 is available, deny boot (in production mode) or fall back
	# on passphrase mode
	if ! tpm2_startup &>/dev/null; then
		warn "No TPM 2.0 detected"
		if $REQUIRE_TPM; then
			deny_boot
		fi
		warn "Falling back on passphrase mode"
		if ! fallback_passphrase; then
			deny_boot
		fi
	else
		info "TPM 2.0 available"
		declare -r efibootdir="/sysroot/mnt/efiboot"
		mount /dev/disk/by-partlabel/EFI "$efibootdir"
		declare -r keyfilesdir="$efibootdir/keyfiles"
		if [[ ! -d "$keyfilesdir" ]]; then
			# This would be the first boot after this machine was installed
			info "No keyfile found, using temporary and dummy passphrase for first boot"
			mkdir "$keyfilesdir"

			# Currently we could reboot without even opening core_state but in
			# the future, during installation, we will be setting up stuff in
			# the state partition during first boot
			declare -r tmp_key="clipos"
			if ! open_core_state "keyfile" "$tmp_key"; then
				warn "Could not open core_state with dummy passphrase"
				rmdir "$keyfilesdir"
				deny_boot
			fi

			if ! setup_tpm2; then
				warn "Could not setup the TPM"
				deny_boot
			fi

			# Generate new 128B keyfile and try to seal it
			KEYFILE="$(dd status=none conv=notrunc if=/dev/urandom \
				bs=$KEYFILE_SIZE count=1 | tr '\0' '0')"

			# WARNING: this assumes we are booting with final secure boot setup!
			if ! seal_keyfile "$keyfilesdir"; then
				rmdir "$keyfilesdir"
				deny_boot
			fi

			# FIXME: test returns of two following cryptsetup commands. What if
			# they fail?

			# Insert keyfile into keyslot
			echo -n "${tmp_key}${KEYFILE}" | cryptsetup luksAddKey \
				"/dev/mapper/${VG_NAME}-core_state" - --key-file - \
				--keyfile-size ${#tmp_key} --new-keyfile-size $KEYFILE_SIZE

			# Remove temporary keyfile from keyslot
			echo -n "$tmp_key" | cryptsetup luksRemoveKey \
				"/dev/mapper/${VG_NAME}-core_state" -
		else
			# Unseal keyfile
			if ! unseal_keyfile "$keyfilesdir"; then
				# List PCRs so admin can then start to diagnose
				tpm2_pcrread "$PCRS_ALL"
				deny_boot
			fi
			if ! open_core_state "keyfile" "$KEYFILE"; then
				warn "Could not open LUKS device"
				deny_boot
			fi
		fi
		rm -f "$POLICY_DIGEST"
		umount "$efibootdir"
	fi
	mount /dev/mapper/core_state /sysroot/mnt/state -t ext4 -o rw,nodev,noexec,nosuid
}

info() {
	echo "$@" >&1
}

warn() {
	echo "$@" >&2
}

setup_tpm2() {
	declare -r primary_context="${TMPFS}/primary.context"
	# Clear owner, endorsement and lockout hierarchy authorization values
	tpm2_clear --quiet || return 1

	# Set temporary random authorization value for the owner hierarchy
	declare -r owner_auth="$(dd status=none conv=notrunc if=/dev/urandom \
							 bs=32 count=1 | tr '\0' '0')"
	if ! tpm2_changeauth --quiet --object-context=owner \
			"file:-" <<< "$owner_auth"; then
		return 1
	fi

	# Create TPM_SE_TRIAL PCR-based policy session
	if ! tpm2_createpolicy --quiet --policy-algorithm=sha256 --policy-pcr \
			--pcr-list="$PCRS_ALL" --policy="$POLICY_DIGEST"; then
		return 1
	fi

	# Derive a primary key from the owner seed and make it persistent
	# FIXME: use better algorithms? (ecc available)
	local attr="fixedtpm|fixedparent|sensitivedataorigin|decrypt|restricted|adminwithpolicy"
	if ! $BRUTEFORCE_LOCKOUT ; then
		attr+="|noda"
	fi
	if ! tpm2_createprimary --quiet --attributes="$attr" \
			--hierarchy=o --hierarchy-auth="file:-" \
			--policy="$POLICY_DIGEST" --key-context="$primary_context" \
			--hash-algorithm=sha256 --key-algorithm=rsa <<< "$owner_auth" ; then
		return 1
	fi
	if ! tpm2_evictcontrol --quiet --hierarchy=o --auth="file:-" \
			--object-context="$primary_context" "$PRIMARY_HANDLE" \
			<<< "$owner_auth"; then
		return 1
	fi

	rm -f "$primary_context"
	return 0
}

seal_keyfile() {
	readonly outfile="${1}/state_keyfile"
	info "Sealing $outfile with the TPM..."
	# Key algorithm cannot be specified as only TPM_ALG_KEYEDHASH is allowed
	# when sealing data
	if ! echo -n "$KEYFILE" | tpm2_create --quiet --hash-algorithm=sha256 \
			--parent-context="$PRIMARY_HANDLE" --parent-auth="pcr:$PCRS_ALL" \
			--attributes="fixedtpm|fixedparent|adminwithpolicy" \
			--policy="$POLICY_DIGEST" --sealing-input=- \
			--public="${outfile}.pub" --private="${outfile}.priv"; then
		warn "Failed to seal $outfile"
		return 1
	fi
	info "$outfile sealed"
}

unseal_keyfile() {
	readonly infile="${1}/state_keyfile"
	info "Unsealing $infile with the TPM"
	if ! tpm2_load --quiet --key-context="$OBJECT_CONTEXT" \
			--parent-context="$PRIMARY_HANDLE" --auth="pcr:$PCRS_ALL" \
			--public="${infile}.pub" --private="${infile}.priv"; then
		warn "Failed to unseal $infile"
		return 1
	fi
	KEYFILE="$(tpm2_unseal --quiet --object-context="$OBJECT_CONTEXT" \
					--auth="pcr:$PCRS_ALL")"
	if [[ -z "$KEYFILE" ]]; then
		warn "Failed to unseal $infile"
		return 1
	fi
	info "$infile unsealed"
	rm -f "$OBJECT_CONTEXT"
}

open_core_state() {
	case "$1" in
		"passphrase")
			local pw="$(systemd-ask-password "Enter passphrase for Core state partition:")"
			echo "${pw}" | cryptsetup open "/dev/mapper/${VG_NAME}-core_state" \
				core_state --type luks
			return $?
			;;
		"keyfile")
			echo -n "$2" | cryptsetup open "/dev/mapper/${VG_NAME}-core_state" \
				core_state --type luks --key-file -
			return $?
			;;
		*)
			return 1
	esac
}

fallback_passphrase() {
	# Keep it simple for now
	open_core_state "passphrase"
}

deny_boot() {
	umount --quiet /dev/disk/by-partlabel/EFI

	warn "Denying further system bootup"
	systemctl --no-block isolate boot-failed.target
	exit 1
}

main

# vim: set ts=4 sts=4 sw=4:
