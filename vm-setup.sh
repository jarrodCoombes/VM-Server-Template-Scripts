#!/usr/bin/env bash
#
# Script:      vm-setup.sh
# Description: All-in-one post-deployment setup for VMs cloned from the
#              Ubuntu server template. Replaces the old 0/1/2/3-numbered
#              script set with one file, organized into functions so each
#              workflow (disk expansion, SSH host key reset, network/hostname
#              config, admin tools, system updates, self-update) can be run
#              independently or in sequence. Workflows that need a reboot
#              set REQUIRE_REBOOT; the reboot prompt happens once, at the end.
#
#              Targets Ubuntu 22.04 through 26.04. Assumes bash 4+ and a
#              netplan-managed, LVM-on-root install (the template's layout).
#
# Usage:       sudo ./vm-setup.sh                  # interactive menu
#              sudo ./vm-setup.sh expand-disk       # run one workflow directly
#              sudo ./vm-setup.sh all               # first-deploy sequence
#              sudo ./vm-setup.sh help              # list all subcommands
#
# ==============================================================================
# SETUP / CONFIGURATION
# ==============================================================================
set -euo pipefail

# --- Constants -----------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
# realpath resolves symlinks so a self-update always overwrites the real file,
# not a symlink pointing at it. Declared separately from assignment so a
# failure in the substitution isn't masked by readonly's own exit status.
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"
readonly SCRIPT_NAME

readonly LOG_FILE="/var/log/vm-setup.log"
readonly MAX_LOG_LINES=5000

# Console colors for log lines that start with "ERROR:" or "WARNING:", so
# problems stand out as output scrolls past. $'...' stores the real escape
# character, not a literal backslash-e. Orange uses the 256-color palette,
# which any modern terminal (and SSH session) supports.
readonly COLOR_ERROR=$'\e[1;31m'      # bold red
readonly COLOR_WARNING=$'\e[38;5;208m' # orange
readonly COLOR_RESET=$'\e[0m'

# Raw URL this script updates itself from. Points at "main" -- the old
# scripts pointed at "master", which is why the update step silently stopped
# working after the repo's default branch was renamed.
readonly UPDATE_URL="https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/main/vm-setup.sh"

# Files touched by the networking workflow. Every existing netplan YAML is
# moved into a timestamped folder under NETPLAN_BACKUP_ROOT and replaced by
# the single NETPLAN_FILE, so leftover configs from the template (or
# cloud-init) can't merge with the new settings. /etc/hosts is backed up in
# place. Either way a bad run can be undone by hand.
readonly NETPLAN_DIR="/etc/netplan"
readonly NETPLAN_FILE="${NETPLAN_DIR}/00-vm-setup-network.yaml"
# Kept outside /etc/netplan on purpose: netplan reads every *.yaml in its
# directory, so backups left there would be applied right alongside the
# new config.
readonly NETPLAN_BACKUP_ROOT="/var/backups/netplan"
readonly HOSTS_FILE="/etc/hosts"

# Admin tools installed by the install-tools workflow. btop and toilet come
# from the "universe" repo, which is enabled by default on Ubuntu Server.
readonly TOOL_PACKAGES=(toilet ncdu btop iftop iotop)

# Login banner settings. The banner goes in the system-wide bashrc so every
# user sees it, not just whoever ran this script. The marker lines bracket
# the block so a re-run can tell it's already there and skip it.
readonly BASHRC_FILE="/etc/bash.bashrc"
readonly BANNER_MARKER_START="# >>> vm-setup hostname banner >>>"
readonly BANNER_MARKER_END="# <<< vm-setup hostname banner <<<"
# "future" is a compact 3-line font from toilet-fonts (pulled in as a toilet
# dependency). The default mono12 is tall and wide enough that longer
# hostnames wrap on an 80-column terminal.
readonly BANNER_FONT="future"

# Ubuntu's own "a reboot is needed" signal. apt creates this file when an
# upgrade touches something that only takes effect on restart (kernel,
# libc, systemd, etc.).
readonly REBOOT_REQUIRED_FILE="/run/reboot-required"

# --- Runtime state -------------------------------------------------------
# Any workflow whose changes need a restart sets this to true instead of
# rebooting on its own. check_reboot reads it once at the end of the run, so
# a multi-step flow like `all` asks about rebooting once rather than
# midway through (which would cut off the remaining steps).
REQUIRE_REBOOT=false

# Defaults offered during the interactive network prompts -- press Enter to
# accept. Centralized here instead of buried inline so updating, say, the
# NTP server doesn't mean hunting through function bodies.
readonly DEFAULT_SUBNET_MASK="255.255.255.0"
readonly DEFAULT_GATEWAY="10.1.1.1"
readonly DEFAULT_DNS_PRIMARY="10.1.1.205"
readonly DEFAULT_DNS_SECONDARY="10.1.1.213"
readonly DEFAULT_NTP_SERVER="time.mpcsd.org"
readonly DEFAULT_TIMEZONE="America/Los_Angeles"

# Soft support window for the OS-version check -- a warning, not a hard
# stop, so a future 26.10 or a backported 22.04 point release doesn't just
# refuse to run.
readonly MIN_SUPPORTED_VERSION="22.04"
readonly MAX_SUPPORTED_VERSION="26.04"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

# --- Logging (from scripts/snippets/logging.sh) --------------------------

# Log output function. Errors print in red and warnings in orange on the
# console; the log file always gets plain text so it stays easy to grep.
# Colors are skipped when stdout isn't a terminal (piped or redirected).
log_message() {
	local message="$1"
	local timestamp line color=""
	timestamp=$(date "+%Y-%m-%d %H:%M:%S")
	line="${timestamp} - ${message}"

	# Built-in defaults, so a script that never defines the COLOR_* globals
	# still works under set -u. Define them in SETUP to override. Kept in
	# variables rather than written inline in the ${...:-...} fallbacks
	# below, because $'...' isn't reliably expanded inside double quotes.
	local default_error=$'\e[1;31m'      # bold red
	local default_warning=$'\e[38;5;208m' # orange
	local default_reset=$'\e[0m'

	case "${message}" in
		ERROR:*)   color="${COLOR_ERROR:-${default_error}}" ;;
		WARNING:*) color="${COLOR_WARNING:-${default_warning}}" ;;
	esac

	if [[ -n "${color}" && -t 1 ]]; then
		echo "${color}${line}${COLOR_RESET:-${default_reset}}"
	else
		echo "${line}"
	fi

	# Console first, then the file: if the log isn't writable (e.g. run
	# without sudo), the message is still shown instead of strict mode
	# killing the script before anything prints.
	# Braces so 2>/dev/null also covers the failed open of LOG_FILE itself.
	{ echo "${line}" >> "${LOG_FILE}"; } 2>/dev/null || true
}

# Log rotation function
rotate_log() {
	if [[ -f "${LOG_FILE}" ]]; then
		local line_count
		# Using redirection to feed wc prevents it from printing the filename
		line_count=$(wc -l < "${LOG_FILE}")
		if (( line_count >= MAX_LOG_LINES )); then
			tail -n "${MAX_LOG_LINES}" "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
		fi
	fi
}

# --- Guards / environment checks ------------------------------------------

# Every workflow needs root (LVM, netplan, ssh host keys, hostnamectl all
# require it), so each cmd_* function calls this first rather than relying
# on the caller to have checked.
require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		log_message "ERROR: This action must be run as root (try: sudo ${SCRIPT_NAME})."
		exit 1
	fi
}

# Warns (does not block) if the OS is outside the versions this script was
# written and tested against. Comparing version strings numerically so
# "26.04" > "22.04" evaluates correctly rather than as a string compare.
check_os_version() {
	if [[ ! -f /etc/os-release ]]; then
		log_message "WARNING: /etc/os-release not found -- cannot verify this is Ubuntu. Proceeding anyway."
		return 0
	fi

	local os_id version_id
	# Sourcing os-release in a subshell keeps its variables from leaking
	# into the rest of this script.
	os_id="$(source /etc/os-release && echo "${ID}")"
	version_id="$(source /etc/os-release && echo "${VERSION_ID}")"

	if [[ "${os_id}" != "ubuntu" ]]; then
		log_message "WARNING: Detected OS '${os_id}', not Ubuntu. This script assumes Ubuntu; proceed with caution."
		return 0
	fi

	if awk -v v="${version_id}" -v min="${MIN_SUPPORTED_VERSION}" 'BEGIN { exit !(v < min) }'; then
		log_message "WARNING: Ubuntu ${version_id} is older than the tested range (${MIN_SUPPORTED_VERSION}-${MAX_SUPPORTED_VERSION})."
	elif awk -v v="${version_id}" -v max="${MAX_SUPPORTED_VERSION}" 'BEGIN { exit !(v > max) }'; then
		log_message "WARNING: Ubuntu ${version_id} is newer than the tested range (${MIN_SUPPORTED_VERSION}-${MAX_SUPPORTED_VERSION}). Things may have changed upstream (netplan, LVM tooling, etc.) -- verify results."
	fi
}

# Copies $1 to "$1.bak.<timestamp>" if it exists. Called before any function
# overwrites a system config file, so a bad run can be manually reverted.
backup_file() {
	local target="$1"
	if [[ -f "${target}" ]]; then
		local backup_path
		backup_path="${target}.bak.$(date +%Y%m%d-%H%M%S)"
		cp -p "${target}" "${backup_path}"
		log_message "Backed up ${target} -> ${backup_path}"
	fi
}

# Copies every *.yaml in NETPLAN_DIR into a new timestamped folder under
# NETPLAN_BACKUP_ROOT, then deletes the originals. Nothing is deleted unless
# every copy succeeded, so a failed backup leaves the old config in place.
backup_and_clear_netplan() {
	local configs=()
	local config
	# nullglob makes the glob expand to nothing (instead of the literal
	# pattern) when no YAML files exist. Scoped to this one expansion.
	shopt -s nullglob
	configs=("${NETPLAN_DIR}"/*.yaml)
	shopt -u nullglob

	if (( ${#configs[@]} == 0 )); then
		log_message "No existing netplan configs in ${NETPLAN_DIR}; nothing to back up."
		return 0
	fi

	local backup_dir
	backup_dir="${NETPLAN_BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
	# 700 because netplan files can hold Wi-Fi passwords and are 600 themselves.
	mkdir -p -m 700 "${backup_dir}"

	for config in "${configs[@]}"; do
		if ! cp -p "${config}" "${backup_dir}/"; then
			log_message "ERROR: Could not back up ${config}. No netplan files were removed."
			return 1
		fi
		log_message "Backed up ${config} -> ${backup_dir}/"
	done

	for config in "${configs[@]}"; do
		rm -f "${config}"
		log_message "Removed ${config}"
	done
}

# --- Validation helpers ----------------------------------------------------

# Returns 0 for a syntactically valid dotted-quad IPv4 address.
validate_ip() {
	local ip="$1"
	local octet
	[[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	local IFS=.
	for octet in ${ip}; do
		(( octet <= 255 )) || return 1
	done
	return 0
}

# Accepts any valid contiguous subnet mask (not just the /8 boundaries the
# old mask2cidr handled) by counting total set bits across all four octets.
mask_to_cidr() {
	local mask="$1"
	local octet cidr=0
	local IFS=.
	for octet in ${mask}; do
		while (( octet > 0 )); do
			cidr=$(( cidr + (octet & 1) ))
			octet=$(( octet >> 1 ))
		done
	done
	echo "${cidr}"
}

# Returns 0 for a plausible FQDN: one or more dot-separated labels ending in
# a TLD-like final label. Not exhaustive (real hostname rules have more
# edge cases) but catches the typical typo (missing dot, stray space, etc.)
# before it gets written into netplan and /etc/hosts.
validate_fqdn() {
	local fqdn="$1"
	[[ "${fqdn}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# Prompts $1 (a message) until validator function $2 accepts the input, or
# the user just presses Enter (in which case $3, the default, is used).
# Echoes the accepted value. Keeps the repetitive "ask, validate, re-ask"
# loop out of configure_network's body.
prompt_validated() {
	local message="$1" validator="$2" default="${3:-}"
	local value
	while true; do
		read -r -p "${message}" value
		if [[ -z "${value}" && -n "${default}" ]]; then
			value="${default}"
		fi
		if "${validator}" "${value}"; then
			echo "${value}"
			return 0
		fi
		echo "  '${value}' doesn't look valid -- try again." >&2
	done
}

# --- Workflow: self-update ---------------------------------------------------

# Downloads the current version of this script from GitHub and replaces
# itself. Fails loudly rather than leaving a half-written script behind:
# downloads to a temp file, checks it's non-empty and passes a bash syntax
# check, and only then overwrites SCRIPT_PATH.
cmd_update() {
	log_message "Checking for a newer version of ${SCRIPT_NAME}..."
	local tmp_file
	tmp_file="$(mktemp)"
	# -f: fail on HTTP errors instead of saving an error page as if it were the script.
	if ! curl -fsSL -o "${tmp_file}" "${UPDATE_URL}"; then
		log_message "ERROR: Could not download ${UPDATE_URL}. Check network access and that the file exists on the 'main' branch."
		rm -f "${tmp_file}"
		return 1
	fi

	if [[ ! -s "${tmp_file}" ]]; then
		log_message "ERROR: Downloaded file was empty. Aborting update."
		rm -f "${tmp_file}"
		return 1
	fi

	if ! bash -n "${tmp_file}"; then
		log_message "ERROR: Downloaded file failed a bash syntax check. Aborting update -- ${SCRIPT_NAME} was left unchanged."
		rm -f "${tmp_file}"
		return 1
	fi

	chmod +x "${tmp_file}"
	mv "${tmp_file}" "${SCRIPT_PATH}"
	log_message "Updated ${SCRIPT_PATH} from ${UPDATE_URL}."
}

# --- Workflow: disk expansion -----------------------------------------------

# Grows the root filesystem to fill all unused space on its disk, in the
# same order as doing it by hand:
#   1. growpart  - stretch each partition backing the root VG to the end
#                  of its disk (new hypervisor space lands after the last
#                  partition, where LVM can't see it)
#   2. pvresize  - tell LVM the partition got bigger
#   3. lvextend  - give the VG's free space to the root logical volume
#   4. grow the filesystem (resize2fs / xfs_growfs / btrfs)
# Detects the root device, VG, partitions and filesystem type at runtime
# (rather than assuming /dev/ubuntu-vg/ubuntu-lv, xvda3 and ext4) so it
# keeps working if the template's layout changes, and so it can be re-run
# any time to pick up a disk that was grown in the hypervisor later.
# Exit codes are checked explicitly instead of relying on strict mode,
# because run_first_deploy calls this with "||", which turns strict mode
# off inside the function.
cmd_expand_disk() {
	require_root
	log_message "Starting disk expansion check."

	local root_device
	root_device="$(findmnt -n -o SOURCE /)"
	log_message "Root filesystem device: ${root_device}"

	# Only LVM logical volumes can be grown this way -- bail out clearly
	# rather than attempting an lvextend that will fail.
	if [[ ! "${root_device}" =~ ^/dev/(mapper/|dm-) ]]; then
		log_message "WARNING: Root filesystem is not on an LVM logical volume (got: ${root_device}). This script only handles the LVM case; skipping."
		return 1
	fi

	local vg_name pv_list
	vg_name="$(lvs --noheadings -o vg_name "${root_device}" | xargs)"
	# awk instead of pvs -S so this works on older lvm2 builds too.
	pv_list="$(pvs --noheadings -o pv_name,vg_name | awk -v vg="${vg_name}" '$2 == vg {print $1}')"
	if [[ -z "${pv_list}" ]]; then
		log_message "ERROR: Could not find the physical volumes for volume group '${vg_name}'."
		return 1
	fi

	if ! command -v growpart >/dev/null 2>&1; then
		log_message "ERROR: growpart is not installed. Install it with 'apt install cloud-guest-utils', then re-run 'expand-disk'."
		return 1
	fi

	# Free space on / before anything changes, for the before/after summary
	# at the end. --output=avail prints just df -h's "Avail" column; tail
	# drops its header and xargs trims the padding.
	local free_before free_after
	free_before="$(df -h --output=avail / | tail -n 1 | xargs)"

	# --- Steps 1 and 2: grow each partition, then its LVM physical volume ---
	local pv pv_kernel_name parent_disk part_num growpart_output growpart_status
	while read -r pv; do
		[[ -z "${pv}" ]] && continue
		# Resolve /dev/mapper-style symlinks to the kernel name (e.g. xvda3)
		# so the sysfs lookups below find it.
		pv_kernel_name="$(basename "$(readlink -f "${pv}")")"

		# Only partitions have a "partition" file in sysfs, holding their
		# number. A PV on a whole disk has no partition to grow, so it
		# skips straight to pvresize.
		if [[ -f "/sys/class/block/${pv_kernel_name}/partition" ]]; then
			part_num="$(< "/sys/class/block/${pv_kernel_name}/partition")"
			parent_disk="$(lsblk -no PKNAME "/dev/${pv_kernel_name}" | head -n 1)"
			log_message "Growing partition ${part_num} on /dev/${parent_disk} to fill the disk..."

			# growpart exits 1 with "NOCHANGE" when the partition already
			# fills the disk. That's fine (the disk may not have been grown),
			# so only treat other failures as errors.
			growpart_status=0
			growpart_output="$(growpart "/dev/${parent_disk}" "${part_num}" 2>&1)" || growpart_status=$?
			echo "${growpart_output}"
			if (( growpart_status != 0 )) && [[ "${growpart_output}" != *NOCHANGE* ]]; then
				log_message "ERROR: growpart failed on /dev/${parent_disk} partition ${part_num} (exit ${growpart_status}). No LVM changes were made."
				return 1
			fi
		fi

		log_message "Resizing LVM physical volume ${pv}..."
		if ! pvresize "${pv}"; then
			log_message "ERROR: pvresize failed on ${pv}. The partition may have grown, but LVM can't use the new space yet."
			return 1
		fi
	done <<< "${pv_list}"

	# --- Step 3: extend the logical volume --------------------------------
	# Report free space before touching the LV, mainly so a re-run that
	# finds nothing to do isn't a mystery.
	local free_extents
	free_extents="$(vgs --noheadings -o vg_free_count "${vg_name}" | xargs)"

	if [[ "${free_extents}" -eq 0 ]]; then
		log_message "WARNING: No free space in volume group '${vg_name}' and no unpartitioned space on the disk. Nothing to expand. (Grow the virtual disk in the hypervisor first, then re-run this.)"
		return 0
	fi

	log_message "Free extents available in '${vg_name}': ${free_extents}. Extending ${root_device}..."
	if ! lvextend -l +100%FREE "${root_device}"; then
		log_message "ERROR: lvextend failed. No filesystem changes were made."
		return 1
	fi

	# --- Step 4: grow the filesystem --------------------------------------
	local fs_type
	fs_type="$(findmnt -n -o FSTYPE /)"
	log_message "Growing filesystem (type: ${fs_type})..."
	local grow_status=0
	case "${fs_type}" in
		ext2|ext3|ext4)
			resize2fs "${root_device}" || grow_status=$?
			;;
		xfs)
			# xfs_growfs takes a mountpoint, not a device.
			xfs_growfs / >/dev/null || grow_status=$?
			;;
		btrfs)
			btrfs filesystem resize max / || grow_status=$?
			;;
		*)
			log_message "WARNING: Logical volume was extended, but '${fs_type}' isn't a filesystem type this script knows how to grow. Extend it manually."
			return 1
			;;
	esac

	if (( grow_status != 0 )); then
		log_message "ERROR: The logical volume was extended, but growing the ${fs_type} filesystem failed (exit ${grow_status}). Grow it manually."
		return 1
	fi

	free_after="$(df -h --output=avail / | tail -n 1 | xargs)"
	log_message "Disk expansion complete. Free space before resize: ${free_before}, free space after resize: ${free_after}."
}

# --- Workflow: SSH host key reset -------------------------------------------

# Removes and regenerates the SSH host keys so clones of the template don't
# all share the same host key (which breaks known_hosts checking and can
# trip SSH MITM warnings once more than one clone exists on the network).
# This is destructive and irreversible, and now callable on its own outside
# the original "right after cloning" context, so it confirms unless run
# non-interactively as part of `all` (see main()).
cmd_reset_ssh_keys() {
	require_root
	local force="${1:-false}"

	if [[ "${force}" != "true" ]]; then
		read -r -p "This will permanently delete the current SSH host keys and generate new ones. Continue? [y/N] " reply
		if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
			log_message "SSH host key reset cancelled by user."
			return 0
		fi
	fi

	log_message "Removing existing SSH host keys."
	rm -fv /etc/ssh/ssh_host_* | while read -r line; do log_message "  ${line}"; done

	# Each step is checked explicitly instead of relying on strict mode,
	# because run_first_deploy calls this with "||", which turns strict
	# mode off inside the function.
	log_message "Regenerating SSH host keys."
	if ! dpkg-reconfigure openssh-server; then
		log_message "ERROR: Regenerating SSH host keys failed. The old keys are already deleted -- run 'sudo ssh-keygen -A' before closing this session, or SSH logins will fail."
		return 1
	fi

	log_message "Restarting SSH service."
	if ! systemctl restart ssh; then
		log_message "ERROR: New SSH host keys were generated, but restarting the ssh service failed. Check 'systemctl status ssh'."
		return 1
	fi

	log_message "SSH host key reset complete."
}

# --- Workflow: hostname / networking ----------------------------------------

# Finds the interface currently holding the default route, rather than
# assuming a fixed name like "enX0". This is the piece most likely to
# differ across hypervisors/NIC drivers and across Ubuntu versions, so it's
# detected instead of hardcoded.
detect_primary_interface() {
	local iface
	iface="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
	if [[ -z "${iface}" ]]; then
		# Fall back to the first "UP" interface that isn't loopback, for the
		# rare case a default route isn't set yet.
		iface="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')"
	fi
	echo "${iface}"
}

# Interactive walkthrough that sets the hostname, FQDN, and static network
# config. Moves every existing netplan YAML to a backup folder and writes a
# single new one, and rewrites /etc/hosts after backing it up. Sets
# REQUIRE_REBOOT, since a hostname change doesn't reach
# already-running services and shells until a restart.
cmd_configure_network() {
	require_root

	local iface
	iface="$(detect_primary_interface)"
	if [[ -z "${iface}" ]]; then
		log_message "ERROR: Could not detect a network interface. Aborting."
		return 1
	fi
	
	echo "This will configure the VM's hostname and static network settings."
	echo "Detected primary network interface: ${iface}"
	echo "You can re-run this at any time to change these settings."
	echo

	local fqdn ip_addr subnet_mask gateway pri_dns sec_dns time_server
	fqdn=$(prompt_validated "FQDN (e.g. server01.mpcsd.org): " validate_fqdn)
	ip_addr=$(prompt_validated "IP address: " validate_ip)
	subnet_mask=$(prompt_validated "Subnet mask [${DEFAULT_SUBNET_MASK}]: " validate_ip "${DEFAULT_SUBNET_MASK}")
	gateway=$(prompt_validated "Gateway [${DEFAULT_GATEWAY}]: " validate_ip "${DEFAULT_GATEWAY}")
	pri_dns=$(prompt_validated "Primary DNS [${DEFAULT_DNS_PRIMARY}]: " validate_ip "${DEFAULT_DNS_PRIMARY}")
	sec_dns=$(prompt_validated "Secondary DNS [${DEFAULT_DNS_SECONDARY}]: " validate_ip "${DEFAULT_DNS_SECONDARY}")
	read -r -p "NTP server [${DEFAULT_NTP_SERVER}]: " time_server
	time_server="${time_server:-${DEFAULT_NTP_SERVER}}"

	local cidr host_name domain_name
	cidr=$(mask_to_cidr "${subnet_mask}")
	host_name="${fqdn%%.*}"
	domain_name="${fqdn#*.}"

	echo
	echo "-------------------------------------------"
	echo "Interface:    ${iface}"
	echo "IP Address:   ${ip_addr}/${cidr}"
	echo "Gateway:      ${gateway}"
	echo "DNS Servers:  ${pri_dns}, ${sec_dns}"
	echo "FQDN:         ${fqdn}  (host: ${host_name}, domain: ${domain_name})"
	echo "NTP Server:   ${time_server}"
	echo "-------------------------------------------"
	read -r -p "Apply this configuration? [y/N] " confirm
	if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
		log_message "Network configuration cancelled by user."
		return 0
	fi

	backup_and_clear_netplan
	backup_file "${HOSTS_FILE}"

	log_message "Writing ${NETPLAN_FILE} for interface ${iface}."
	# A heredoc keeps this one write instead of a dozen appended echo lines,
	# and makes the resulting YAML's structure easy to eyeball for mistakes.
	cat > "${NETPLAN_FILE}" <<-EOF
	# Managed by ${SCRIPT_NAME} -- last written $(date "+%Y-%m-%d %H:%M:%S")
	network:
	  version: 2
	  renderer: networkd
	  ethernets:
	    ${iface}:
	      addresses: [${ip_addr}/${cidr}]
	      nameservers:
	        search: [${domain_name}]
	        addresses: [${pri_dns}, ${sec_dns}]
	      routes:
	        - to: default
	          via: ${gateway}
	EOF
	
	chmod 600 "${NETPLAN_FILE}"

	log_message "Writing ${HOSTS_FILE}."
	cat > "${HOSTS_FILE}" <<-EOF
	127.0.0.1 localhost
	${ip_addr} ${fqdn} ${host_name}

	# The following lines are desirable for IPv6 capable hosts
	::1 localhost ip6-localhost ip6-loopback
	ff02::1 ip6-allnodes
	ff02::2 ip6-allrouters
	EOF

	log_message "Setting hostname to ${host_name}."
	hostnamectl set-hostname "${host_name}"

	log_message "Applying netplan configuration."
	netplan apply

	log_message "Testing connectivity to gateway ${gateway}..."
	if ! ping -q -c 1 "${gateway}" > /dev/null; then
		log_message "WARNING: Could not reach gateway. Retrying with debug logging to netplan-debug.log..."
		netplan --debug apply > netplan-debug.log 2>&1 || true
		if ! ping -q -c 2 "${gateway}" >> netplan-debug.log 2>&1; then
			log_message "ERROR: Network is still unreachable. Check netplan-debug.log and the interface/cabling, then re-run 'configure-network'."
			return 1
		fi
	fi
	log_message "Network connection established."

	log_message "Setting timezone to ${DEFAULT_TIMEZONE}."
	timedatectl set-timezone "${DEFAULT_TIMEZONE}"

	log_message "NTP server ${time_server} was collected but this script does not configure an NTP client -- confirm systemd-timesyncd or chrony is pointed at it separately if needed."

	REQUIRE_REBOOT=true
	log_message "Network configuration complete. A reboot is needed for the new hostname to take full effect."
}

# --- Workflow: admin tools / login banner -----------------------------------

# Appends a block to the system-wide bashrc that prints the short hostname
# in large text whenever an interactive shell starts. The hostname is looked
# up at login time (not baked in now), so the banner stays correct after
# configure-network renames the machine. Skips if the block already exists.
install_login_banner() {
	if grep -qF "${BANNER_MARKER_START}" "${BASHRC_FILE}"; then
		log_message "Login banner already present in ${BASHRC_FILE}; leaving it as-is."
		return 0
	fi

	backup_file "${BASHRC_FILE}"
	log_message "Adding hostname login banner to ${BASHRC_FILE}."
	# The body lines are indented with spaces, not tabs, because <<- strips
	# leading tabs. \$ escapes keep those expansions literal in the file so
	# they run at each login instead of once, right now.
	cat >> "${BASHRC_FILE}" <<-EOF

	${BANNER_MARKER_START}
	# Added by ${SCRIPT_NAME}: shows this machine's hostname at login.
	# Interactive shells only, so scp/rsync/scripted SSH output isn't polluted.
	if [[ \$- == *i* ]] && command -v toilet >/dev/null 2>&1; then
	    echo -e "\e[1;31m\$(toilet -f ${BANNER_FONT} -F center "\$(hostname -s)")\e[0m"
	fi
	${BANNER_MARKER_END}
	EOF
}

# Installs the standard admin toolset (TOOL_PACKAGES) and adds the toilet
# hostname banner. Safe to re-run: apt skips packages that are already
# installed, and install_login_banner won't add a second copy of the block.
cmd_install_tools() {
	require_root

	log_message "Refreshing package lists."
	if ! apt update; then
		log_message "ERROR: apt update failed. Check network access, then re-run 'install-tools'."
		return 1
	fi

	log_message "Installing admin tools: ${TOOL_PACKAGES[*]}"
	if ! apt install -y "${TOOL_PACKAGES[@]}"; then
		log_message "ERROR: Package install failed. Check that the 'universe' repository is enabled (btop and toilet live there)."
		return 1
	fi

	install_login_banner
	log_message "Admin tools install complete. The banner shows up in new login shells."
}

# --- Workflow: system updates ----------------------------------------------

# Installs all pending package updates. Sets REQUIRE_REBOOT if apt left the
# reboot-required flag behind, so a kernel update gets a reboot prompt but a
# run that only touched userland packages doesn't.
cmd_system_update() {
	require_root

	log_message "Refreshing package lists."
	if ! apt update; then
		log_message "ERROR: apt update failed. Check network access, then re-run 'system-update'."
		return 1
	fi

	log_message "Installing package updates."
	if ! apt upgrade -y; then
		log_message "ERROR: apt upgrade failed. Review the apt output above, then re-run 'system-update'."
		return 1
	fi

	if [[ -f "${REBOOT_REQUIRED_FILE}" ]]; then
		REQUIRE_REBOOT=true
		log_message "System updates complete. These updates need a reboot to take effect."
	else
		log_message "System updates complete."
	fi
}

# --- Reboot handling -----------------------------------------------------------

# Asks before rebooting, so a run on a box someone is actively using never
# restarts it unannounced.
reboot_system() {
	read -r -p "A reboot is needed to finish setup. Reboot now? [y/N] " reply
	if [[ "${reply}" =~ ^[Yy]$ ]]; then
		log_message "Rebooting."
		reboot
	else
		log_message "Reboot skipped -- reboot before relying on these changes."
	fi
}

# Runs once at the end of every workflow run (see main) and reboots only if
# something this run set REQUIRE_REBOOT.
check_reboot() {
	if [[ "${REQUIRE_REBOOT}" == "true" ]]; then
		reboot_system
	else
		log_message "No reboot needed."
	fi
}

# --- Workflow: first-deploy sequence ---------------------------------------

# The full post-clone flow. configure-network runs as a plain call so strict
# mode stops the run if it fails -- there's no point installing packages
# on a box whose network setup failed. Tools and updates come after it
# because a fresh clone may not reach the internet until it has run. Every
# later step logs its failure and carries on: by then the network changes
# are already applied, so the run has to reach the reboot check in main.
run_first_deploy() {
	cmd_configure_network
	cmd_reset_ssh_keys true || log_message "ERROR: SSH host key reset failed. Fix it (see above), then re-run 'reset-ssh'."
	cmd_expand_disk || log_message "WARNING: Disk expansion failed. Re-run 'expand-disk' later."
	cmd_install_tools || log_message "WARNING: Admin tools install failed. Re-run 'install-tools' later."
	cmd_system_update || log_message "WARNING: System updates failed. Re-run 'system-update' later."
}

# --- Menu / help -------------------------------------------------------------

usage() {
	cat <<-EOF
	${SCRIPT_NAME} v${SCRIPT_VERSION}

	Usage: sudo ./${SCRIPT_NAME} [command]

	Commands:
	  update               Pull the latest version of this script from GitHub
	  expand-disk          Grow the root filesystem to fill free VG space (safe to re-run any time)
	  reset-ssh            Regenerate SSH host keys (asks for confirmation)
	  configure-network    Interactive hostname/IP/DNS setup
	  install-tools        Install admin tools (${TOOL_PACKAGES[*]}) and the hostname login banner
	  system-update        Install all pending package updates (apt upgrade)
	  all                  First-deploy flow: configure-network, reset-ssh, expand-disk,
	                       install-tools, system-update, then reboot if needed
	  help                 Show this message

	Running with no command opens an interactive menu. Any command that needs
	a reboot asks about it once, at the end of the run.
	EOF
}

show_menu() {
	echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
	echo "1) Update this script"
	echo "2) Expand disk"
	echo "3) Reset SSH host keys"
	echo "4) Configure hostname/networking"
	echo "5) Install admin tools and login banner"
	echo "6) Install system updates"
	echo "7) Run full first-deploy sequence (configure-network -> reset-ssh -> expand-disk -> install-tools -> system-update)"
	echo "8) Exit"
	read -r -p "Choose an option [1-8]: " choice
	case "${choice}" in
		1) cmd_update ;;
		2) cmd_expand_disk ;;
		3) cmd_reset_ssh_keys ;;
		4) cmd_configure_network ;;
		5) cmd_install_tools ;;
		6) cmd_system_update ;;
		7) run_first_deploy ;;
		8) exit 0 ;;
		*) echo "Not a valid option." ;;
	esac
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
	rotate_log
	check_os_version

	case "${1:-}" in
		update)             cmd_update ;;
		expand-disk)        cmd_expand_disk ;;
		reset-ssh)          cmd_reset_ssh_keys ;;
		configure-network)  cmd_configure_network ;;
		install-tools)      cmd_install_tools ;;
		system-update)      cmd_system_update ;;
		all)                run_first_deploy ;;
		# Help changes nothing, so return before the reboot check.
		help|-h|--help)     usage; return 0 ;;
		"")                 show_menu ;;
		*)
			log_message "ERROR: Unknown command: ${1}"
			usage
			exit 1
			;;
	esac

	# One reboot decision per run, after every step has finished.
	check_reboot
}

main "$@"
