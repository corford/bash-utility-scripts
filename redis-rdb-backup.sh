#!/bin/bash
#
# Takes an RDB backup of a running redis instance and stores it
# as an lzop compressed tar archive.
#
# In order to guarantee an up to date snapshot, the script
# asks redis to perform a BGSAVE operation prior to creating
# the RDB file.
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
E_BACKUP=5


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

TAR_BIN="$(which tar)"
LZOP_BIN="$(which lzop)"
REDIS_CLI_BIN="$(which redis-cli)"


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

function create_tmp_workspace ()
{
    mkdir "${1}" || return 1
    chmod 700 "${1}"

    return 0
}

function do_backup ()
{
    START_TIME=$(date +%s)

    log "${SCRIPT_NAME}: Taking backup..."

    # Verify backup dir exists and is writeable
    if ! test_dir_is_writeable "${1}"; then log true "${SCRIPT_NAME}: Error! Backup directory '${1}' does not exist (or is not writeable). Aborting."; exit ${E_BACKUP}; fi

    # Create temporary workspace
    WORKSPACE="/tmp/.redis_backup_wspace_${RANDOM}"
    create_tmp_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Record the unixtime of the last successful DB SAVE redis performed
    LAST_SAVE=$("${7}" -h ${5} -p ${6} --raw LASTSAVE) || exit ${E_BACKUP}

    # Instruct redis to perform a BGSAVE (so any pending changes since the last SAVE are flushed to disk)
    "${7}" -h ${5} -p ${6} --raw BGSAVE &>/dev/null || exit ${E_BACKUP}

    # Poll redis to monitor status of BGSAVE operation
    POLL_INTERVAL_SECS=1
    POLL_COUNT=0
    MAX_POLLS=480
    DO_POLL=1
    while [ ${DO_POLL} -ne 0 -a ${POLL_COUNT} -lt ${MAX_POLLS} ]; do
        NEW_LAST_SAVE=$("${7}" -h ${5} -p ${6} --raw LASTSAVE) || exit ${E_BACKUP}

        if [ ${NEW_LAST_SAVE} -gt ${LAST_SAVE} ]; then
            DO_POLL=0
        else
            let POLL_COUNT++

            if [ ${POLL_COUNT} -ne ${MAX_POLLS} ]; then
                sleep ${POLL_INTERVAL_SECS}
            else
                log true "${SCRIPT_NAME}: Error! Timeout while waiting for redis to finish BGSAVE operation. Aborting."; exit ${E_BACKUP};
            fi
        fi
    done

    # Fetch redis rdb file
    FETCHED_RDB_FILE="${WORKSPACE}/dump.rdb"
    "${7}" -h ${5} -p ${6} --rdb "${FETCHED_RDB_FILE}" &>/dev/null || exit ${E_BACKUP}

    # Tar and compress with lzop
    log "${SCRIPT_NAME}: Compressing..."
    BACKUP_FILE="${2}.$(date +%Y-%m-%dT%H-%M-%S).tar.lzo"
    "${8}" -cf - -C "${WORKSPACE}" . | "${9}" -5 > "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_BACKUP}

    # Set permissions
    chmod 600 "${WORKSPACE}/${BACKUP_FILE}"

    # Set owner
    chown ${3} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

    # Set group
    chgrp ${4} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

    # Remove any previous backup(s) at destination
    rm -f "${1}/${2}"*.tar.lzo || exit ${E_PKG}

    # Move backup to destination
    mv "${WORKSPACE}/${BACKUP_FILE}" "${1}/${BACKUP_FILE}" || exit ${E_PKG}

    # Remove temporary workspace
    log "${SCRIPT_NAME}: Cleaning up..."
    rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}

    log "${SCRIPT_NAME}: Backup complete (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hd:f:o:g:r:p:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        d)
            BACKUP_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        f)
            BACKUP_FILE_PREFIX="${OPTARG}"
            ;;
        o)
            BACKUP_FILE_OWNER=${OPTARG}
            ;;
        g)
            BACKUP_FILE_GROUP=${OPTARG}
            ;;
        r)
            REDIS_HOST=${OPTARG}
            ;;
        p)
            REDIS_PORT=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -d backup_dir -f backup_file_prefix -o backup_file_owner -o backup_file_group -r redis_host -p redis_port"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check tar is available
if ! test_bin "${TAR_BIN}"; then echo 'Could not find "tar"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check lzop is available
if ! test_bin "${LZOP_BIN}"; then echo 'Could not find "lzop"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check redis-cli is available
if ! test_bin "${REDIS_CLI_BIN}"; then echo 'Could not find "redis-cli"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${BACKUP_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REDIS_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REDIS_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

do_backup "${BACKUP_DIR}" "${BACKUP_FILE_PREFIX}" "${BACKUP_FILE_OWNER}" "${BACKUP_FILE_GROUP}" "${REDIS_HOST}" "${REDIS_PORT}" "${REDIS_CLI_BIN}" "${TAR_BIN}" "${LZOP_BIN}"

exit 0
