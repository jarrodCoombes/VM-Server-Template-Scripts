#!/usr/bin/env bash
#
# Script:      vm-setup.sh
# Description: All-in-one post-deployment setup for VMs cloned from the
#              Ubuntu server template. Replaces the old 0/1/2/3-numbered
#              script set with one file, organized into functions so each
#              workflow (disk expansion, SSH host key reset, network/hostname
#              config, self-update) can be run independently or in sequence.
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

# Raw URL this script updates itself from. Points at "main" -- the old
# scripts pointed at "master", which is why the update step silently stopped
# working after the repo's default branch was renamed.
readonly UPDATE_URL="https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/main/vm-setup.sh"

# Files touched by the networking workflow. Both are backed up (timestamped)
# before being overwritten, so a bad run can be undone by hand.
readonly NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
readonly HOSTS_FILE="/etc/hosts"

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

# Log output function
log_message() {
	local message="$1"
	local timestamp
	timestamp=$(date "+%Y-%m-%d %H:%M:%S")
	echo "${timestamp} - ${message}" | tee -a "${LOG_FILE}"
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

# Grows the root filesystem to fill whatever free space exists in its
# volume group. Detects the root device and filesystem type at runtime
# (rather than assuming /dev/ubuntu-vg/ubuntu-lv and ext4) so it keeps
# working if the template's VG/LV names change, and so it can be re-run any
# time -- not just right after cloning -- to pick up a disk that was grown
# in the hypervisor later.
cmd_expand_disk() {
	require_root
	log_message "Starting disk expansion check."

	local root_device
	root_device="$(findmnt -n -o SOURCE /)"
	log_message "Root filesystem device: ${root_device}"

	# Only LVM logical volumes can be grown this way. A plain partition
	# (no LVM) needs growpart instead, which is a different workflow --
	# bail out clearly rather than attempting an lvextend that will fail.
	if [[ ! "${root_device}" =~ ^/dev/(mapper/|dm-) ]]; then
		log_message "Root filesystem is not on an LVM logical volume (got: ${root_device}). This script only handles the LVM case; skipping."
		return 1
	fi

	# Report free space before touching anything, mainly so a re-run that
	# finds nothing to do isn't a mystery.
	local vg_name free_extents
	vg_name="$(lvs --noheadings -o vg_name "${root_device}" | xargs)"
	free_extents="$(vgs --noheadings -o vg_free_count "${vg_name}" | xargs)"

	if [[ "${free_extents}" -eq 0 ]]; then
		log_message "No free space in volume group '${vg_name}'. Nothing to expand. (Grow the virtual disk in the hypervisor first, then re-run this.)"
		return 0
	fi

	log_message "Free extents available in '${vg_name}': ${free_extents}. Extending ${root_device}..."
	if ! lvextend -l +100%FREE "${root_device}"; then
		log_message "ERROR: lvextend failed. No filesystem changes were made."
		return 1
	fi

	local fs_type
	fs_type="$(findmnt -n -o FSTYPE /)"
	log_message "Growing filesystem (type: ${fs_type})..."
	case "${fs_type}" in
		ext2|ext3|ext4)
			resize2fs "${root_device}"
			;;
		xfs)
			# xfs_growfs takes a mountpoint, not a device.
			xfs_growfs / >/dev/null
			;;
		btrfs)
			btrfs filesystem resize max /
			;;
		*)
			log_message "WARNING: Logical volume was extended, but '${fs_type}' isn't a filesystem type this script knows how to grow. Extend it manually."
			return 1
			;;
	esac

	log_message "Disk expansion complete."
	df -h /
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

	log_message "Regenerating SSH host keys."
	dpkg-reconfigure openssh-server

	log_message "Restarting SSH service."
	systemctl restart ssh

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
# config, replacing netplan's config and /etc/hosts. Backs up both files
# first. Ends with an apt upgrade and an optional reboot.
cmd_configure_network() {
	require_root

	local iface
	iface="$(detect_primary_interface)"
	if [[ -z "${iface}" ]]; then
		log_message "ERROR: Could not detect a network interface. Aborting."
		return 1
	fi

	clear
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

	backup_file "${NETPLAN_FILE}"
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

	log_message "Fetching latest package updates."
	apt update
	apt upgrade -y

	read -r -p "Setup is complete. Reboot now? [y/N] " reboot_confirm
	if [[ "${reboot_confirm}" =~ ^[Yy]$ ]]; then
		log_message "Rebooting."
		reboot
	else
		log_message "Reboot skipped -- remember to reboot before this configuration is fully active."
	fi
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
	  all                  Run expand-disk, reset-ssh, and configure-network in sequence (first-deploy flow)
	  help                 Show this message

	Running with no command opens an interactive menu.
	EOF
}

show_menu() {
	echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
	echo "1) Update this script"
	echo "2) Expand disk"
	echo "3) Reset SSH host keys"
	echo "4) Configure hostname/networking"
	echo "5) Run full first-deploy sequence (expand-disk -> reset-ssh -> configure-network)"
	echo "6) Exit"
	read -r -p "Choose an option [1-6]: " choice
	case "${choice}" in
		1) cmd_update ;;
		2) cmd_expand_disk ;;
		3) cmd_reset_ssh_keys ;;
		4) cmd_configure_network ;;
		5) cmd_expand_disk && cmd_reset_ssh_keys true && cmd_configure_network ;;
		6) exit 0 ;;
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
		all)                cmd_expand_disk && cmd_reset_ssh_keys true && cmd_configure_network ;;
		help|-h|--help)     usage ;;
		"")                 show_menu ;;
		*)
			echo "Unknown command: ${1}" >&2
			usage
			exit 1
			;;
	esac
}

main "$@"
