#!/bin/bash
#
# Takes an RDB backup of a running redis instance and stores it
# as a gzip compressed tar archive.
#
# Execute with -h flag to see required script params.
#
#
# Note: In order to guarantee an up to date snapshot, the script
# asks redis to perform a BGSAVE operation prior to backing up
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
E_WORKSPACE=5
E_BACKUP=6


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

TAR_BIN="$(which tar)"
GZIP_BIN="$(which gzip)"
REDIS_CLI_BIN="$(which redis-cli)"
GZIP_COMPRESSION=4
WORKSPACE_PATH_PREFIX="/tmp/.redis_rdbbackup_wspace_"


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
    chmod 700 "${1}" || return 1

    return 0
}

function do_backup ()
{
    START_TIME=$(date +%s)

    log "${SCRIPT_NAME}: Taking backup..."

    # Verify backup dir exists and is writeable
    if ! test_dir_is_writeable "${1}"; then log true "${SCRIPT_NAME}: Error! Backup directory '${1}' does not exist (or is not writeable). Aborting."; exit ${E_BACKUP}; fi

    # Create temporary workspace
    WORKSPACE="${WORKSPACE_PATH_PREFIX}$(od -N 8 -t uL -An /dev/urandom | sed 's/\s//g')"
    create_tmp_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Record the unixtime of the last successful DB SAVE redis performed
    LAST_SAVE=$("${REDIS_CLI_BIN}" -h ${7} -p ${8} --raw LASTSAVE) || exit ${E_BACKUP}

    # Instruct redis to perform a BGSAVE (so any pending changes since the last SAVE are flushed to disk)
    "${REDIS_CLI_BIN}" -h ${7} -p ${8} --raw BGSAVE &>/dev/null || exit ${E_BACKUP}

    # Poll redis to monitor status of BGSAVE operation
    POLL_INTERVAL_SECS=1
    POLL_COUNT=0
    MAX_POLLS=480
    DO_POLL=1
    while [ ${DO_POLL} -ne 0 -a ${POLL_COUNT} -lt ${MAX_POLLS} ]; do
        NEW_LAST_SAVE=$("${REDIS_CLI_BIN}" -h ${7} -p ${8} --raw LASTSAVE) || exit ${E_BACKUP}

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
    "${REDIS_CLI_BIN}" -h ${7} -p ${8} --rdb "${FETCHED_RDB_FILE}" &>/dev/null || exit ${E_BACKUP}

    # Set backup file name (with or without ISO 8601 timestamp)
    if [ ${6} = "true" ]; then BACKUP_FILE="${2}.$(date +%Y-%m-%dT%H-%M-%S).tar.gz"; else BACKUP_FILE="${2}.tar.gz"; fi

    # Tar and compress (Note: --transform 's/^\.//' is not supported by BSD tar, use -s '/.//' instead)
    log "${SCRIPT_NAME}: Compressing..."
    touch "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    "${TAR_BIN}" --exclude="${BACKUP_FILE}" --transform 's/^\.//' -cf - -C "${WORKSPACE}" . | "${GZIP_BIN}" -q -${GZIP_COMPRESSION} > "${WORKSPACE}/${BACKUP_FILE}"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! tar or gzip reported an error. Aborting."; exit ${E_PKG}; fi

    # Secure the backup
    chown ${3} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    chgrp ${4} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    chmod ${5} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

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
OPTSPEC=":hd:f:o:g:m:t:r:p:"
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
        m)
            BACKUP_FILE_MODE=${OPTARG}
            ;;
        t)
            BACKUP_FILE_TIMESTAMP=${OPTARG} # If 'true', ISO 8601 timestamp will be auto-appended to backup_file_prefix
            ;;
        r)
            REDIS_HOST=${OPTARG}
            ;;
        p)
            REDIS_PORT=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -d backup_dir -f backup_file_prefix -o backup_file_owner -o backup_file_group -m backup_file_mode -t true|false -r redis_host -p redis_port"
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

# Check gzip is available
if ! test_bin "${GZIP_BIN}"; then echo 'Could not find "gzip"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check redis-cli is available
if ! test_bin "${REDIS_CLI_BIN}"; then echo 'Could not find "redis-cli"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${BACKUP_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_TIMESTAMP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REDIS_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REDIS_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

do_backup "${BACKUP_DIR}" "${BACKUP_FILE_PREFIX}" "${BACKUP_FILE_OWNER}" "${BACKUP_FILE_GROUP}" ${BACKUP_FILE_MODE} ${BACKUP_FILE_TIMESTAMP} "${REDIS_HOST}" "${REDIS_PORT}"

exit 0
