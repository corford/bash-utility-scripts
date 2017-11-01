#!/bin/bash
#
# Mirrors a local directory (and its children) to a remote location using rsync
# or lftp (useful when the remote host doesn't allow or support rsync e.g. an
# sftp-only jail). Supports bandwidth limiting.
#
# Execute with -h flag to see required script params.
#
#
# Note 1: Files and dirs not present in the source directory will be deleted from
# the remote directory. Hidden files or dirs (dot files) will not be mirrored.
#
# Note 2: Remember to add the public key of the host running this script to the
# authorized_keys file of the remote host.
#

# ////////////////////////////////////////////////////////////////////
# ENV VARS AND ERROR CODES
# ////////////////////////////////////////////////////////////////////

# Don't touch unless you know what you're doing
SCRIPT_PATH="$(cd "${0%/*}" 2>/dev/null; echo "$(pwd -P)"/"${0##*/}")"
SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

# Error codes
E_INVALID_OPT=1
E_MISSING_ARG=2
E_MISSING_DEPENDENCY=3
E_SOURCE=4
E_MIRROR=5


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

LOGFILE="/dev/null"
RSYNC_BIN=$(which rsync)
LFTP_BIN=$(which lftp)


# ////////////////////////////////////////////////////////////////////
# FUNCTIONS
# ////////////////////////////////////////////////////////////////////

function log ()
{
    # Log message goes to stderr (in addition to syslog) when
    # true is passed as the first arg to this function

    if [ $# -eq 2 ]; then
        echo "${2}" >&2
        logger "${2}"

    else
        echo "${1}"
        logger "${1}"

    fi

    return 0
}

function test_bin ()
{
    test -x "${1}" || return 1

    return 0
}

function test_var ()
{
    if [ -z "${1+xxx}" ]; then return 1; fi # var is not set
    if [ -z "$1" -a "${1+xxx}" = "xxx" ]; then return 2; fi # var is set but empty

    return 0
}

function test_dir_exists ()
{
    if ! [ -r "${1}" -a -d "${1}" ]; then
        return 1
    fi

    return 0
}

function test_dir_is_writeable ()
{
    if ! [ -w "${1}" -a -d "${1}" ]; then
        return 1
    fi

    return 0
}

function test_file_exists ()
{
    if ! [ -r "${1}" -a -f "${1}" ]; then
        return 1
    fi

    return 0
}

function do_mirror ()
{
    START_TIME=$(date +%s)

    log "${SCRIPT_NAME}: Mirroring source to target..."

    # Verify source dir exists
    if ! test_dir_exists "${1}"; then log true "${SCRIPT_NAME}: Error! Source directory '${1}' does not exist. Aborting."; exit ${E_SOURCE}; fi

    # Mirror with lftp
    if [ "${8}" = "lftp" ]; then
        "${LFTP_BIN}" -e "set net:limit-max ${5}K; set net:timeout ${6}; set net:max-retries 10; set net:reconnect-interval-base 3; set net:reconnect-interval-max 3; set net:reconnect-interval-multiplier 1; mirror -R -e -c -x '(^|/)\.' --log=${7} ${1} ${4}; quit" -u ${3}, sftp://${2} || exit ${E_MIRROR}

    # Mirror with rsync (default)
    else
        "${RSYNC_BIN}" -aq --exclude=".*" --exclude=".*/" --safe-links --delete-after --bwlimit=${5} --timeout=${6} --log-file=${7} "${1}/" "${3}@${2}:${4}" || exit ${E_MIRROR}

    fi

    log "${SCRIPT_NAME}: Done (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hs:r:u:p:l:t:e:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        s)
            SOURCE_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        r)
            REMOTE_HOST=${OPTARG}
            ;;
        u)
            REMOTE_USER=${OPTARG}
            ;;
        p)
            REMOTE_PATH=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        l)
            BWLIMIT_KB=${OPTARG}
            ;;
        t)
            TIMEOUT_SECS=${OPTARG}
            ;;
        e)
            ENGINE=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -s source_dir -r remote_host -u remote_user -p remote_path -l bandwidth_limit_kb -t timeout_secs -e rsync|lftp"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check rsync is available
if ! test_bin "${RSYNC_BIN}"; then echo 'Could not find "rsync"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check lftp is available
if ! test_bin "${LFTP_BIN}"; then echo 'Could not find "lftp"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${SOURCE_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_PATH}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BWLIMIT_KB}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${TIMEOUT_SECS}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${ENGINE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Perform mirror
do_mirror "${SOURCE_DIR}" ${REMOTE_HOST} ${REMOTE_USER} "${REMOTE_PATH}" ${BWLIMIT_KB} ${TIMEOUT_SECS} ${LOGFILE} ${ENGINE}

exit 0
