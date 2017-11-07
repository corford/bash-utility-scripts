#!/bin/bash
#
# Takes a backup of a postgresql cluster's roles, db schemas and, optionally,
# table data.
#
# Execute with -h flag to see required script params.
#
# Note 1: connection credentials will be taken from a postgresql .pgpass file
# if one is present in the home dir of the user running this script.
#
# Note 2:
# Resulting backup archive layout (template0, template1 and postgres databases
# are always ignored by this script):
#
# - backup.tar.gz
# --| roles.sql
# --| dbname1
# ----| schema.sql
# ----| data.sql [ if `-a true` is passed to this script ]
# --| dbname2
# ----| schema.sql
# ----| data.sql [ if `-a true` is passed to this script ]
# ... etc
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

TAR_BIN="$(which tar)"
GZIP_BIN="$(which gzip)"
PGDUMP_BIN="$(which pg_dump)"
PGDUMPALL_BIN="$(which pg_dumpall)"
PSQL_BIN="$(which psql)"
GZIP_COMPRESSION=4
WORKSPACE_PATH_PREFIX="/tmp/.pgsql_simplebackup_wspace_"


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

    # Dump cluster roles
    log "${SCRIPT_NAME}: Dumping cluster roles"
    "${PGDUMPALL_BIN}" -g --quote-all-identifiers --clean --if-exists -h "${7}" -p "${8}" -U "${9}" | sed -e '/^--/d' > "${WORKSPACE}/roles.sql"
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then exit ${E_BACKUP}; fi

    chmod 600 "${WORKSPACE}/roles.sql" || exit ${E_BACKUP}

    # Get list of databases (exclude postgres, template0 and template1)
    DATABASES=$("${PSQL_BIN}" -h "${7}" -p "${8}" -U "${9}" -d postgres -q -A -t -c "SELECT datname FROM pg_database WHERE datname !='template0' AND datname !='template1' AND datname !='postgres'")

    # Check there were no errors
    if [ $? -ne 0 ]; then exit ${E_BACKUP}; fi

    # Verify we have a valid list
    if ! test_var ${DATABASES}; then log true "${SCRIPT_NAME}: Error! No database(s) found. Aborting."; exit ${E_BACKUP}; fi

    # Dump schemas and table data
    NUM_DATABASES=${#DATABASES[@]}
    for DB in ${DATABASES[@]}; do
        mkdir "${WORKSPACE}/${DB}" || exit ${E_BACKUP}

        chmod 700 "${WORKSPACE}/${DB}" || exit ${E_BACKUP}

        log "${SCRIPT_NAME}: Dumping '${DB}' schema"
        "${PGDUMP_BIN}" -s --quote-all-identifiers --clean --if-exists -h "${7}" -p "${8}" -U "${9}" -d "${DB}" | sed -e '/^--/d' > "${WORKSPACE}/${DB}/schema.sql"

        if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then exit ${E_BACKUP}; fi

        chmod 600 "${WORKSPACE}/${DB}/schema.sql"

        # Check if table data should be included in the backup
        if [ ${10} = "true" ]; then
            log "${SCRIPT_NAME}: Dumping '${DB}' tables"
            "${PGDUMP_BIN}" --quote-all-identifiers --no-unlogged-table-data --data-only --encoding=UTF-8 -h "${7}" -p "${8}" -U "${9}" -d "${DB}" 2>/dev/null | sed -e '/^--/d' > "${WORKSPACE}/${DB}/data.sql"

            if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

            chmod 600 "${WORKSPACE}/${DB}/data.sql"
        fi
    done

    # Set backup file name (with or without ISO 8601 timestamp)
    if [ ${6} = "true" ]; then BACKUP_FILE="${2}.$(date +%Y-%m-%dT%H-%M-%S).tar.gz"; else BACKUP_FILE="${2}.tar.gz"; fi

    # Tar and compress
    touch "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    "${TAR_BIN}" --exclude="${BACKUP_FILE}" -cf - -C "${WORKSPACE}" . | "${GZIP_BIN}" -q -${GZIP_COMPRESSION} > "${WORKSPACE}/${BACKUP_FILE}"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then exit ${E_PKG}; fi

    # Secure the backup
    chown ${3} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    chgrp ${4} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}
    chmod ${5} "${WORKSPACE}/${BACKUP_FILE}" || exit ${E_PKG}

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
OPTSPEC=":hd:f:o:g:m:t:r:p:u:a:"
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
            PGSQL_HOST=${OPTARG}
            ;;
        p)
            PGSQL_PORT=${OPTARG}
            ;;
        u)
            PGSQL_USER=${OPTARG}
            ;;
        a)
            INCLUDE_TABLE_DATA=${OPTARG} # If true, dumped table data for each database will be included in the backup
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -d backup_dir -f backup_file_prefix -o backup_file_owner -g backup_file_group -m backup_file_mode -t true|false -r pgsql_host -p pgsql_port -u pgsql_user -a true|false"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid option: -${OPTARG} (for usage instructions, execute this script again with just the -h flag)" >&2
            exit ${E_INVALID_OPT}
            ;;
    esac
done

# Check tar is available (required by pg_basebackup)
if ! test_bin "${TAR_BIN}"; then echo 'Could not find "tar"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check gzip is available
if ! test_bin "${GZIP_BIN}"; then echo 'Could not find "gzip"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check pg_dump is available
if ! test_bin "${PGDUMP_BIN}"; then echo 'Could not find "pg_dump"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check pg_dumpall is available
if ! test_bin "${PGDUMPALL_BIN}"; then echo 'Could not find "pg_dumpall"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check psql is available
if ! test_bin "${PSQL_BIN}"; then echo 'Could not find "psql"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${BACKUP_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${BACKUP_FILE_TIMESTAMP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${INCLUDE_TABLE_DATA}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

do_backup "${BACKUP_DIR}" "${BACKUP_FILE_PREFIX}" "${BACKUP_FILE_OWNER}" "${BACKUP_FILE_GROUP}" ${BACKUP_FILE_MODE} ${BACKUP_FILE_TIMESTAMP} "${PGSQL_HOST}" "${PGSQL_PORT}" "${PGSQL_USER}" ${INCLUDE_TABLE_DATA}

exit 0
