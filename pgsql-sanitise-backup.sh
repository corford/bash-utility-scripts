#!/bin/bash
#
# Alters role passwords generated by pg_dumpall.
#
# Execute with -h flag to see required script params.
#
#
# Why ?
# Useful for resetting production passwords so developers can use a backup to stand-up
# a new dev instance of a postgres cluster without needing to be given prod credentials.
#
# Note 1:
# Source file is expected to be a gzip compressed tar archive containing at least a
# cluster role file dumped with `pg_dumpall -g --quote-all-identifiers` (in virtually
# all cases the tar archive would also contain schema and/or table data for all the
# databases in the cluster i.e. the source archive would be a backup produced with
# something like pgsql-meta-backup.sh)
#
# Note 2:
# Resulting export tar.gz will mimic the contents of the source archive (except the
# roles.sql file in the archive will have been modified with the new password for
# ALL users). If the role file is not called "roles.sql" and located at the root of
# the source archive, modify the $ROLE_FILE global var below to point to the correct
# place within the original backup.
#
# Note 3:
# Script sets the new password as an MD5 hash according to the postgresql spec:
# password concatenated with username and resulting hash prefixed with 'md5'
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
E_EXPORT=6
E_PASSWORD_RESET=7
E_PKG=8


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

TAR_BIN="$(which tar)"
GZIP_BIN="$(which gzip)"
MD5SUM_BIN="$(which md5sum)"
GZIP_COMPRESSION=4
WORKSPACE_PATH_PREFIX="/tmp/.pgsql_sanitise_wspace_"

# Name (and relative path within original backup archive) of file containing
# cluster roles dumped by `pg_dumpall -g --quote-all-identifiers`
ROLE_FILE="roles.sql"


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

function do_password_reset ()
{
    # Check if we should reset all passwords
    if [ ! "${2}" = "!" ]; then
        # Isolate role users from role file
        ROLES=$(cat "${1}/${ROLE_FILE}" | sed -e '/^ALTER ROLE.*PASSWORD/{s/WITH.*//}' -e '/^ALTER ROLE.*/!d' -e 's/ALTER ROLE "//' -e 's/"//' -e 's/\s//g'; exit $(( $? + ${PIPESTATUS[0]} )))

        # Check there were no errors
        if [ $? -ne 0 ]; then return 1; fi

        # Store in a bash array
        IFS=$'\n' read -rd '' -a USERS <<<"$ROLES"

        # Check we have some role users to work with
        if [ ! "${#USERS[@]}" -gt 0 ]; then log true "${SCRIPT_NAME}: Error! No role users found."; return 1; fi

        # Reset password for ALL role users
        for USER in "${USERS[@]}"
        do
            log "${SCRIPT_NAME}: Resetting role password for user '${USER}'..."
            PASSWORD=$(echo -n "${2}${USER}" | "${MD5SUM_BIN}" | cut -d' ' -f1) # Generate MD5 password according to postgres spec
            sed -i "/^ALTER ROLE \"${USER}\"/{s/PASSWORD '[a-z0-9]*'/PASSWORD 'md5${PASSWORD}'/}" "${1}/${ROLE_FILE}" || return 1 # In-place replace
        done
    fi

    return 0
}

function do_conversion ()
{
    START_TIME=$(date +%s)

    # Verify source dir exists
    if ! test_dir_exists "${1}"; then log true "${SCRIPT_NAME}: Error! Source directory '${1}' does not exist. Aborting."; exit ${E_SOURCE}; fi

    # Locate source file (this is the latest file found in the source directory whose name starts with the given prefix)
    IFS= read -r -d '' SOURCE_FILE \
      < <(find "${1}" -type f -name "${2}*" -printf '%T@ %p\0' | sort -znr)
    SOURCE_FILE=${SOURCE_FILE#* }

    # Verify source file is valid
    if ! test_var ${SOURCE_FILE} -a test_file_exists "${SOURCE_FILE}"; then log true "${SCRIPT_NAME}: Error! Could not locate source file. Aborting."; exit ${E_SOURCE}; fi

    # Verify export dir exists and is writeable
    if ! test_dir_is_writeable "${3}"; then log true "${SCRIPT_NAME}: Error! Export directory '${3}' does not exist (or is not writeable). Aborting."; exit ${E_EXPORT}; fi

    # Create temporary workspace
    WORKSPACE="${WORKSPACE_PATH_PREFIX}$(od -N 8 -t uL -An /dev/urandom | sed 's/\s//g')"
    create_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Extract source backup to workspace
    "${GZIP_BIN}" -d < "${SOURCE_FILE}" | "${TAR_BIN}" -C "${WORKSPACE}" -x -p -f - || exit ${E_EXPORT}

    # Set export file name (with or without ISO 8601 timestamp)
    if [ ${8} = "true" ]; then EXPORT_FILE="${4}.$(date +%Y-%m-%dT%H-%M-%S).tar.gz"; else EXPORT_FILE="${4}.tar.gz"; fi

    # Reset role user passwords
    if ! do_password_reset "${WORKSPACE}" "${9}"; then exit ${E_PASSWORD_RESET}; fi

    # Tar and compress
    touch "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}
    "${TAR_BIN}" --exclude="${EXPORT_FILE}" -cf - -C "${WORKSPACE}" . | "${GZIP_BIN}" -q -${GZIP_COMPRESSION} > "${WORKSPACE}/${EXPORT_FILE}"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then exit ${E_PKG}; fi

    # Secure the export
    chown ${5} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}
    chgrp ${6} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}
    chmod ${7} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}

    # Move to destination
    log "${SCRIPT_NAME}: Moving compressed export to '${3}/${EXPORT_FILE}'"
    mv "${WORKSPACE}/${EXPORT_FILE}" "${3}/${EXPORT_FILE}" || exit ${E_PKG}

    # Remove temporary workspace
    rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}

    log "${SCRIPT_NAME}: Done (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hs:f:e:n:o:g:m:t:x:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        s)
            SOURCE_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        f)
            SOURCE_FILE_PREFIX=${OPTARG}
            ;;
        e)
            EXPORT_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        n)
            EXPORT_FILE_PREFIX="${OPTARG}"
            ;;
        o)
            EXPORT_OWNER=${OPTARG}
            ;;
        g)
            EXPORT_GROUP=${OPTARG}
            ;;
        m)
            EXPORT_FILE_MODE=${OPTARG}
            ;;
        t)
            EXPORT_FILE_TIMESTAMP=${OPTARG} # If 'true', ISO 8601 timestamp will be auto-appended to export_file_prefix
            ;;
        x)
            NEW_PASSWORD="${OPTARG}"
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -s source_dir -f source_file_prefix -e export_dir -n export_file_prefix -o export_owner -g export_group -m export_file_mode -t true|false [-x new_password]"
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

# Check md5sum is available
if ! test_bin "${MD5SUM_BIN}"; then echo 'Could not find "md5sum"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${SOURCE_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${SOURCE_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE_TIMESTAMP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${NEW_PASSWORD}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Check if we should reset ALL user account passwords
if ! test_var ${NEW_PASSWORD}; then NEW_PASSWORD="!"; fi

# Perform conversion
do_conversion "${SOURCE_DIR}" "${SOURCE_FILE_PREFIX}" "${EXPORT_DIR}" "${EXPORT_FILE_PREFIX}" "${EXPORT_OWNER}" "${EXPORT_GROUP}" ${EXPORT_FILE_MODE} ${EXPORT_FILE_TIMESTAMP} "${NEW_PASSWORD}"

exit 0
