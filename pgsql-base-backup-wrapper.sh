#!/bin/bash
#
# Wrapper script to take a PostgreSQL base backup and store a GPG encrypted
# copy remotely.
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
E_BACKUP=4
E_SECURE_DROP=5


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

# None


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


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":ha:d:f:o:g:r:p:u:b:k:x:y:z:m:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        a)
            BACKUP_SCRIPT="${OPTARG}"
            ;;
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
        b)
            SECURE_DROP_SCRIPT="${OPTARG}"
            ;;
        k)
            GPG_PUB_KEY=${OPTARG}
            ;;
        x)
            REMOTE_SFTP_HOST=${OPTARG}
            ;;
        y)
            REMOTE_SFTP_USER=${OPTARG}
            ;;
        z)
            REMOTE_SFTP_PATH=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        m)
            REMOTE_FILE_MODE=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -a backup_script -d backup_dir -f backup_file_prefix -o backup_file_owner -g backup_file_group -r pgsql_host -p pgsql_port -u pgsql_user -b secure_drop_script -k gpg_key_id -x remote_sftp_host -y remote_sftp_user -z remote_sftp_path -m remote_file_mode"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${BACKUP_SCRIPT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${SECURE_DROP_SCRIPT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${GPG_PUB_KEY}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_PATH}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Take base backup
"${BACKUP_SCRIPT}" -d "${BACKUP_DIR}" -f "${BACKUP_FILE_PREFIX}" -o "${BACKUP_FILE_OWNER}" -g "${BACKUP_FILE_GROUP}" -r "${PGSQL_HOST}" -p ${PGSQL_PORT} -u ${PGSQL_USER} || exit ${E_BACKUP}

# Locate resulting backup file (this is the latest file found in ${BACKUP_DIR} whose name starts with ${BACKUP_FILE_PREFIX}
IFS= read -r -d '' BACKUP_FILE \
    < <(find "${BACKUP_DIR}" -type f -name "${BACKUP_FILE_PREFIX}*" -printf '%T@ %p\0' | sort -znr)
BACKUP_FILE=${BACKUP_FILE#* }

# Verify backup file is valid
if ! test_var ${BACKUP_FILE} -a test_file_exists "${BACKUP_FILE}"; then log true "${SCRIPT_NAME}: Error! Backup file \"${BACKUP_FILE}\" does not exist (or is not readable). Aborting."; exit ${E_BACKUP}; fi

# Encrypt and copy to remote
"${SECURE_DROP_SCRIPT}" -s "${BACKUP_FILE}" -k "${GPG_PUB_KEY}" -r "${REMOTE_SFTP_HOST}" -u ${REMOTE_SFTP_USER} -p "${REMOTE_SFTP_PATH}" -m ${REMOTE_FILE_MODE} || exit ${E_SECURE_DROP}

exit 0
