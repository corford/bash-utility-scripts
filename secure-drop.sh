#!/bin/bash
#
# GPG encrypts a source file (e.g. a compressed tar archive) against a given key
# and transfers it to a remote server via sftp. Useful for e.g. securely copying
# database backups off-site.
#
# Execute with -h flag to see required script params.
#
#
# Note 1:
# Remote filename will be the basename of the source file with ".gpg" appended.
#
# Note 2:
# The public GPG key this script encrypts against must already be imported into
# the default GPG keychain of the user running the script (usually located at
# ~/.gnupg/pubring.gpg). To import a public key, run the following command as the
# script user: gpg --import /path/to/pubkey.txt
#
# Note 3: Remember to add the public key of the host running this script to the
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
E_WORKSPACE=5
E_ENCRYPT=6
E_TRANSFER=7


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

SFTP_BIN="$(which sftp)"
GPG_BIN="$(which gpg)"
WORKSPACE_PATH_PREFIX="/tmp/.secure_drop_wspace_"


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

function create_workspace ()
{
    mkdir "${1}" || return 1
    chmod 700 "${1}" || return 1

    return 0
}

function do_drop ()
{
    START_TIME=$(date +%s)

    # Verify source file exists
    if ! test_file_exists "${1}"; then log true "${SCRIPT_NAME}: Error! Source file '${1}' does not exist (or is not readable). Aborting."; exit ${E_SOURCE}; fi

    # Verify GPG key is available
    "${GPG_BIN}" --list-keys "${6}" >/dev/null || exit ${E_ENCRYPT}

    # Create temporary workspace
    WORKSPACE="${WORKSPACE_PATH_PREFIX}$(od -N 8 -t uL -An /dev/urandom | sed 's/\s//g')"
    create_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Set remote filename as source file with ".gpg" appended
    REMOTE_FILE="$(basename "${1}")".gpg

    log "${SCRIPT_NAME}: Encrypting source file..."
    "${GPG_BIN}" --no-greeting --no-options --no-auto-check-trustdb \
    --cipher-algo AES256 --batch --no-tty -q -e -z 0 -r "${6}" \
    -o "${WORKSPACE}/${REMOTE_FILE}" "${1}" || exit ${E_ENCRYPT}

    log "${SCRIPT_NAME}: Transferring to remote..."
    "${SFTP_BIN}" -o PasswordAuthentication=no -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET -q -b - ${3}@${2}:"${4}" <<END &>/dev/null
put "${WORKSPACE}/${REMOTE_FILE}"
chmod ${5} "${REMOTE_FILE}"
quit
END

    if [ $? -ne 0 ]; then
        log true "${SCRIPT_NAME}: Error! sftp reported an error. Aborting."
        rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}
        exit ${E_TRANSFER}
    fi

    # Remove workspace
    rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}

    log "${SCRIPT_NAME}: Done (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hs:k:r:u:p:m:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        s)
            SOURCE_FILE=${OPTARG}
            ;;
        k)
            GPG_PUB_KEY=${OPTARG}
            ;;
        r)
            REMOTE_SFTP_HOST=${OPTARG}
            ;;
        u)
            REMOTE_SFTP_USER=${OPTARG}
            ;;
        p)
            REMOTE_SFTP_PATH=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        m)
            REMOTE_FILE_MODE=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -s source_file -k gpg_pub_key_id -r remote_sftp_host -u remote_sftp_user -p remote_sftp_path -m remote_file_mode"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check sftp is available
if ! test_bin "${SFTP_BIN}"; then echo 'Could not find "sftp"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check gpg is available
if ! test_bin "${GPG_BIN}"; then echo 'Could not find "gpg"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${SOURCE_FILE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${GPG_PUB_KEY}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_PATH}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_SFTP_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${REMOTE_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

do_drop "${SOURCE_FILE}" "${REMOTE_SFTP_HOST}" ${REMOTE_SFTP_USER} "${REMOTE_SFTP_PATH}" ${REMOTE_FILE_MODE} ${GPG_PUB_KEY}

exit 0
