#!/bin/bash
#
# Imports a basebackup of a master PostgreSQL server to an intermediary server and
# re-exports as an lzop compressed tar archive of raw sql files (produced with pg_dump).
#
# Why ?
#
# Backups produced with pg_basebackup give an opaque (and large) database snapshot.
# Re-exporting with pg_dump lets you seperate role, schema and table data in to smaller
# discrete SQL files that can be more easily moved around and imported to systems other
# than PostgresSQL.
#
# Script has to import and export through an intermediary postgesql server because pg_dump
# cannot (yet) work directly with pg_basebackup snapshots.
#
# Note 1:
# Source file is expected to be an lzop compressed tar archive produced by pg_basebackup
#
# Note 2:
# Intermediary postgres server is expected to run on the same host as this script and
# needs an hba trust entry for local connections. Server does not need to be accessible
# to the outside world (indeed, for security, it should not be).
#
# Note 3:
# Resulting export archive layout (template0, template1 and postgres databases
# are always ignored by this script):
#
# - export.tar.lzo
# --| cluster-roles.sql
# --| dbname1
# ----| db-schema.sql
# ----| db-data.sql
# --| dbname2
# ----| db-schema.sql
# ----| db-data.sql
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
E_SOURCE=4
E_WORKSPACE=5
E_EXPORT=6
E_IMPORT=7
E_DUMP=8
E_PKG=9


# ////////////////////////////////////////////////////////////////////
# BINPATHS AND GLOBALS
# ////////////////////////////////////////////////////////////////////

LZOP_BIN="$(which lzop)"
TAR_BIN="$(which tar)"
SERVICE_BIN="$(which service)"
PGDUMP_BIN="$(which pg_dump)"
PGDUMPALL_BIN="$(which pg_dumpall)"
PSQL_BIN="$(which psql)"


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
    chmod 700 "${1}"

    return 0
}

function do_import ()
{
    # Stop postgres
    "${5}" postgresql stop
    sleep 5

    # Remove old postgres data dir (if present) and extract basebackup in to place
    test_dir_is_writeable "$(dirname "${3}")" || return 1
    if test_dir_exists "${3}"; then rm -rf "${3}" || return 1; fi
    mkdir "${3}" || return 1
    chmod 700 "${3}" || return 1
    chown postgres:postgres "${3}" || return 1
    log "${SCRIPT_NAME}: Extracting basebackup to \"${3}\"..."
    "${4}" -d < "${1}" | "${2}" -C "${3}" -x -p -f - || return 1

    # Start postgres
    "${5}" postgresql start
    sleep 45

    log "${SCRIPT_NAME}: Import complete"

    return 0
}


function do_export ()
{
    # Get list of databases to dump (exclude postgres, template0 and template1)
    DATABASES=$("${7}" -h localhost -U "${4}" -d postgres -q -A -t -c "SELECT dbname FROM pg_database WHERE dbname !='template0' AND dbname !='template1' AND dbname !='postgres'")

    # Verify we have a valid list
    if ! test_var ${DATABASES}; then log true "${SCRIPT_NAME}: Error! No database(s) found. Aborting."; return 1; fi

    # Dump cluster roles
    log "${SCRIPT_NAME}: Dumping cluster roles to \"${1}/cluster-roles.sql\""
    "${5}" -g --quote-all-identifiers --clean --if-exists -h "${2}" -p "${3}" -U "${4}" | sed -e '/^--/d' > "${1}/cluster-roles.sql"
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! pg_dumpall or sed reported an error. Aborting."; return 1; fi

    chmod 600 "${1}/cluster-roles.sql"

    NUM_DATABASES=${#DATABASES[@]}
    log "${SCRIPT_NAME}: Found ${NUM_DATABASES} database(s)"

    for DB in ${DATABASES[@]}; do
        log "${SCRIPT_NAME}: Dumping database \"${DB}\" to \"${1}/${DB}\"..."

        mkdir "${1}/${DB}" || return 1

        chmod 700 "${1}/${DB}"

        "${6}" -s --quote-all-identifiers --clean --if-exists -h "${2}" -p "${3}" -U "${4}" -d "${DB}" | sed -e '/^--/d' > "${1}/${DB}/db-schema.sql"
        if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! pg_dump or sed reported an error. Aborting."; return 1; fi

        chmod 600 "${1}/${DB}/db-schema.sql"

        "${6}" --quote-all-identifiers --no-unlogged-table-data --data-only --encoding=UTF-8 -h "${2}" -p "${3}" -U "${4}" -d "${DB}" 2>/dev/null | sed -e '/^--/d' > "${1}/${DB}/db-data.sql"
        if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! pg_dump or sed reported an error. Aborting."; return 1; fi

        chmod 600 "${1}/${DB}/db-data.sql"
    done

    # Tar and compress
    "${8}" -cf - -C "${1}" . | "${9}" -5 > "${1}/export.tar.lzo"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then log true "${SCRIPT_NAME}: Error! tar or lzop reported an error. Aborting."; return 1; fi

    return 0
}


function do_conversion ()
{
    START_TIME=$(date +%s)

    # Verify source dir exists
    if ! test_dir_exists "${1}"; then log true "${SCRIPT_NAME}: Error! Source directory \"${1}\" does not exist. Aborting."; exit ${E_SOURCE}; fi

    # Locate source file (this is the latest file found in the source directory whose name starts with the given prefix)
    IFS= read -r -d '' SOURCE_FILE \
      < <(find "${1}" -type f -name "${2}*" -printf '%T@ %p\0' | sort -znr)
    SOURCE_FILE=${SOURCE_FILE#* }

    # Verify source file is valid
    if ! test_var ${SOURCE_FILE} -a test_file_exists "${SOURCE_FILE}"; then log true "${SCRIPT_NAME}: Error! Source file \"${SOURCE_FILE}\" does not exist (or is not readable). Aborting."; exit ${E_SOURCE}; fi

    # Verify export dir exists and is writeable
    if ! test_dir_is_writeable "${4}"; then log true "${SCRIPT_NAME}: Error! Export directory \"${4}\" does not exist (or is not writeable). Aborting."; exit ${E_EXPORT}; fi

    # Create temporary workspace
    WORKSPACE="/tmp/.pgsql_export_wspace_${RANDOM}"
    create_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Import basebackup
    do_import "${SOURCE_FILE}" "${14}" "${3}" "${15}" "${16}" || exit ${E_IMPORT}

    # Export raw sql as an lzop compressed tar archive
    do_export "${WORKSPACE}" "${8}" "${9}" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" || exit ${E_DUMP}

    # Secure the export
    chmod 600 "${WORKSPACE}/export.tar.lzo"
    chown ${6} "${WORKSPACE}/export.tar.lzo" || exit ${E_PKG}
    chgrp ${7} "${WORKSPACE}/export.tar.lzo" || exit ${E_PKG}

    # Move to destination
    log "${SCRIPT_NAME}: Moving compressed export to \"${4}/${5}\""
    mv "${WORKSPACE}/export.tar.lzo" "${4}/${5}" || exit ${E_PKG}

    # Remove temporary workspace
    rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}

    log "${SCRIPT_NAME}: Converion complete (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hs:f:i:e:n:o:g:a:p:u:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        s)
            SOURCE_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        f)
            SOURCE_FILE_PREFIX=${OPTARG}
            ;;
        i)
            IMPORT_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        e)
            EXPORT_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        n)
            EXPORT_FILE="${OPTARG}" 
            ;;
        o)
            EXPORT_OWNER=${OPTARG}
            ;;
        g)
            EXPORT_GROUP=${OPTARG}
            ;;
        a)
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
            echo "Usage: ${SCRIPT_NAME} -s source_dir -f source_file_prefix -i import_dir -e export_dir -n export_file -o export_owner -g export_group -a intermediary_pgsql_host -p intermediary_pgsql_port -u intermediary_pgsql_super_user"
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

# Check tar is available
if ! test_bin "${TAR_BIN}"; then echo 'Could not find "tar"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check service is available
if ! test_bin "${SERVICE_BIN}"; then echo 'Could not find "service"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check pg_dump is available
if ! test_bin "${PGDUMP_BIN}"; then echo 'Could not find "pg_dump"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check pg_dumpall is available
if ! test_bin "${PGDUMPALL_BIN}"; then echo 'Could not find "pg_dumpall"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check psql is available
if ! test_bin "${PSQL_BIN}"; then echo 'Could not find "psql"' >&2; exit ${E_MISSING_DEPENDENCY}; fi

# Check required script arguments are present
E_MSG="Missing or invalid script argument(s). For usage instructions, execute this script again with just the -h flag."
if ! test_var ${SOURCE_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${SOURCE_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${IMPORT_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_DIR}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Perform conversion
do_conversion "${SOURCE_DIR}" "${SOURCE_FILE_PREFIX}" "${IMPORT_DIR}" "${EXPORT_DIR}" "${EXPORT_FILE}" "${EXPORT_OWNER}" "${EXPORT_GROUP}" "${PGSQL_HOST}" "${PGSQL_PORT}" "${PGSQL_USER}" "${PGDUMPALL_BIN}" "${PGDUMP_BIN}" "${PSQL_BIN}" "${TAR_BIN}" "${LZOP_BIN}" "${SERVICE_BIN}"

exit 0
