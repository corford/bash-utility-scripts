#!/bin/bash
#
# Ships postgres WAL archive files to a remote location using lftp
#
# Note: remote SFTP path must be absolute (i.e. begin with a /)
#

# ////////////////////////////////////////////////////////////////////
# ENV VARS AND ERROR CODES
# ////////////////////////////////////////////////////////////////////

# Don't touch unless you know what you're doing
SCRIPT_PATH="$(cd "${0%/*}" 2>/dev/null; echo "$(pwd -P)"/"${0##*/}")"
SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

# Error return codes
E_INVALID_OPT=1
E_MISSING_ARG=2
E_MISSING_DEPENDENCY=3
E_SOURCE=5
E_ARCHIVE=6


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

ADMIN_EMAIL="root@localhost"
MAILX_BIN=$(which mailx)
LFTP_BIN=$(which lftp)


# ////////////////////////////////////////////////////////////////////
# FUNCTIONS
# ////////////////////////////////////////////////////////////////////

function log ()
{
    # Log message goes to stderr (in addition to syslog) and trigger an
    # email alert when true is passed as the first arg to this function

    if [ $# -eq 2 ]; then
        echo "${2}" >&2
        logger "${2}"
        alert "${2}"

    else
        echo "${1}"
        logger "${1}"

    fi

    return 0
}

function alert ()
{
    echo "${1}" | "${MAILX_BIN}" -s "Postgres WAL archiving FAILED" "${ADMIN_EMAIL}"
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

function test_remote_file_exists ()
{
    # LFTP allows running `find` remotely (which is in the SFTP protocol but not supported by stock sftp)
    "${5}" -e "find ${1} || exit 1; quit;" -u ${3}, sftp://${2}/${4} &>/dev/null

    if [ $? -eq 0 ]; then
        return 1
    fi

    return 0
}

function archive_wal_file ()
{
    "${7}" -e "put ${1} || exit 1; chmod ${6} ${2} || exit 1; quit;" -u ${4}, sftp://${3}/${5} &>/dev/null

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":ha:f:r:u:p:m:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        a)
            WAL_ABSOLUTE_FILE_NAME="${OPTARG}"
            ;;
        f)
            WAL_FILE_NAME="${OPTARG}"
            ;;
        r)
            REMOTE_SFTP_HOST="${OPTARG}"
            ;;
        u)
            REMOTE_SFTP_USER="${OPTARG}"
            ;;
        p)
            REMOTE_SFTP_PATH=$(echo "${OPTARG}" | sed -e "s/^\/*//" | sed -e "s/\/*$//")
            ;;
        m)
            REMOTE_FILE_MODE=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -a wal_absolute_file_name -f wal_file_name -r remote_sftp_host -u remote_sftp_user -p remote_sftp_path -m remote_file_mode"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check mailx is available
if ! test_bin "${MAILX_BIN}"; then echo 'Could not find "mailx"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check lftp is available
if ! test_bin "${LFTP_BIN}"; then echo 'Could not find "lftp"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${WAL_ABSOLUTE_FILE_NAME}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${WAL_FILE_NAME}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_PATH}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Check WAL file exists locally
if ! test_file_exists "${WAL_ABSOLUTE_FILE_NAME}"; then log true "${SCRIPT_NAME}: Error! Local WAL file \"${WAL_ABSOLUTE_FILE_NAME}\" does not exist (or is not readable). File was not archived."; exit ${E_SOURCE}; fi

# Check WAL file doesn't already exist at the remote destination
if ! test_remote_file_exists "${WAL_FILE_NAME}" ${REMOTE_SFTP_HOST} ${REMOTE_SFTP_USER} "${REMOTE_SFTP_PATH}" "${LFTP_BIN}"; then log true "${SCRIPT_NAME}: Error! WAL file \"${WAL_FILE_NAME}\" already exists at remote. File was not archived."; exit ${E_ARCHIVE}; fi

# Archive WAL file
if ! archive_wal_file "${WAL_ABSOLUTE_FILE_NAME}" "${WAL_FILE_NAME}" ${REMOTE_SFTP_HOST} ${REMOTE_SFTP_USER} "${REMOTE_SFTP_PATH}" ${REMOTE_FILE_MODE} "${LFTP_BIN}"; then log true "${SCRIPT_NAME}: Error! Problem sending WAL file \"${WAL_ABSOLUTE_FILE_NAME}\" to remote. File was not archived."; exit ${E_ARCHIVE}; fi

exit 0
