#!/bin/bash
#
# Takes a base backup of a running pgsql cluster and stores it in a
# compressed tar archive. lzop is used for compression (favouring
# speed and lighter CPU work over a smaller file size).
#
# Execute with -h flag to see required script params.
#
# NOTE: a Postgresql .pgpass file (placed in the home dir of the user
# running the script) is required. It should contain replication
# credentials for the pgsql cluser being backed up with pg_basebackup.
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
E_BACKUP=4
E_WORKSPACE=5
E_PKG=6


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

LZOP_BIN="$(which lzop)"
PGBASEBACKUP_BIN="$(which pg_basebackup)"


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
    if ! test_dir_is_writeable "${1}"; then log true "${SCRIPT_NAME}: Error! Backup directory \"${1}\" does not exist (or is not writeable). Aborting."; exit ${E_BACKUP}; fi

    # Create temporary workspace
    WORKSPACE="/tmp/.pgsql_backup_wspace_${RANDOM}"
    create_tmp_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Take postgres base backup and compress resulting tar archive with lzop
    BACKUP_FILE="${2}.$(date +%Y-%m-%dT%H-%M-%S).tar.lzo"   
    "${5}" -U "${6}" -h ${7} -p ${8} -w -c fast -X fetch -D - -Ft | "${9}" -5 > "${WORKSPACE}/${BACKUP_FILE}"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! pg_basebackup or lzop reported an error. Aborting."; exit ${E_BACKUP}; fi

    # Set permissions
    chmod 600 "${WORKSPACE}/${BACKUP_FILE}"

    # Set owner
    chown ${3} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

    # Set group
    chgrp ${4} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

    # Remove any previous backup(s) at destination
    rm -f "${1}/${2}"*.tar.lzo || exit ${E_PKG}

    # Move base backup to destination
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
OPTSPEC=":hd:f:o:g:r:p:u:"
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
            PGSQL_HOST=${OPTARG}
            ;;
        p)
            PGSQL_PORT=${OPTARG}
            ;;
        u)
            PGSQL_USER=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -d backup_dir -f backup_file_prefix -o backup_file_owner -g backup_file_group -r pgsql_host -p pgsql_port -u pgsql_user"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check lzop is available
if ! test_bin "${LZOP_BIN}"; then echo 'Could not find "lzop"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check pg_basebackup is available
if ! test_bin "${PGBASEBACKUP_BIN}"; then echo 'Could not find "pg_basebackup"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${BACKUP_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

do_backup "${BACKUP_DIR}" "${BACKUP_FILE_PREFIX}" "${BACKUP_FILE_OWNER}" "${BACKUP_FILE_GROUP}" "${PGBASEBACKUP_BIN}" "${PGSQL_USER}" "${PGSQL_HOST}" "${PGSQL_PORT}" "${LZOP_BIN}"

exit 0
