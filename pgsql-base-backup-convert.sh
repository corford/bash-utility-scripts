#!/bin/bash
#
# Imports a backup of a master postgresql server (produced with pg_basebackup) to an
# intermediary server and re-exports it as a gzip compressed tar archive of raw sql
# files (produced with pg_dumpall and pg_dump).
#
# Execute with -h flag to see required script params.
#
#
# Why ?
#
# Backups produced with pg_basebackup give an opaque (and large) database snapshot.
# Re-exporting with pg_dumpall/pg_dump allows the seperation of role, schema and table
# data in to discrete SQL files that can be more easily moved around (they compress well),
# sanitised and imported to systems other than postgresql.
#
# This script has to import and export through an intermediary postgesql server because
# pg_dumpall and pg_dump cannot (yet) work directly with pg_basebackup snapshots.
#
# Note 1:
# Source file is expected to be a gzip compressed tar archive produced with pg_basebackup
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
# - export.tar.gz
# --| roles.sql
# --| dbname1
# ----| schema.sql
# ----| data.sql
# --| dbname2
# ----| schema.sql
# ----| data.sql
# ... etc
#
# Note 4:
# Use the optional -x and -z flags to perform santising on the SQL data prior to export.
# Passing -x mynewpassword will change the password for ALL user accounts/roles (including
# the super user) to 'mynewpassword'. Use the -z flag to pass the absolute path of a file
# containing SQL commands you wish to apply to table data before exporting (e.g. altering 
# senstivie user details like email addresses). Each line in the file should be in the
# format: 'db_name:sql_command;' (without the single quotes). Example line:
# mydb:UPDATE users SET email = 'dummy@example.com';
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

TAR_BIN="$(which tar)"
GZIP_BIN="$(which gzip)"
SERVICE_BIN="$(which service)"
PGDUMP_BIN="$(which pg_dump)"
PGDUMPALL_BIN="$(which pg_dumpall)"
PSQL_BIN="$(which psql)"

GZIP_COMPRESSION=4
WORKSPACE_PATH_PREFIX="/tmp/.pgsql_convert_wspace_"
POSTGRES_SERIVCE_NAME="postgresql"
POSTGRES_OWNER="postgres"
POSTGRES_GROUP="postgres"
POSTGRES_STOP_SERIVCE_WAIT_SECS="5"
POSTGRES_START_SERIVCE_WAIT_SECS="120"


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

function do_import ()
{
    # Stop postgres
    "${SERVICE_BIN}" ${POSTGRES_SERIVCE_NAME} stop
    sleep ${POSTGRES_STOP_SERIVCE_WAIT_SECS}

    # Remove old postgres data dir (if present) and extract basebackup in to place
    test_dir_is_writeable "$(dirname "${2}")" || return 1
    if test_dir_exists "${2}"; then rm -rf "${2}" || return 1; fi
    mkdir "${2}" || return 1
    chmod 700 "${2}" || return 1
    chown ${POSTGRES_OWNER}:${POSTGRES_GROUP} "${2}" || return 1
    log "${SCRIPT_NAME}: Extracting basebackup to \"${2}\"..."
    "${GZIP_BIN}" -d < "${1}" | "${TAR_BIN}" -C "${2}" -x -p -f -
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

    # Start postgres
    "${SERVICE_BIN}" ${POSTGRES_SERIVCE_NAME} start
    sleep ${POSTGRES_START_SERIVCE_WAIT_SECS}

    log "${SCRIPT_NAME}: Import complete"

    return 0
}

function do_processing ()
{
    # Check if we should reset all passwords
    if [ ! "${4}" = "!" ]; then
        # Get list of cluster users
        USERS=$("${PSQL_BIN}" -h "${1}" -p "${2}" -U "${3}" -d postgres -q -t -c '\du' | cut -f1 -d '|' | sed 's/\s//g' | sed '/^\s*$/d'; exit $(( $? + ${PIPESTATUS[0]} + ${PIPESTATUS[1]} + ${PIPESTATUS[2]} )))

        # Check there were no errors
        if [ $? -ne 0 ]; then return 1; fi

        # Verify we have a valid list
        if ! test_var ${USERS}; then log true "${SCRIPT_NAME}: Error! No users(s) found. Aborting."; return 1; fi

        log "${SCRIPT_NAME}: Changing user passwords..."
        for USER in ${USERS[@]}; do
            "${PSQL_BIN}" -h "${1}" -p "${2}" -U "${3}" -d postgres -q -c "ALTER USER ${USER} WITH ENCRYPTED PASSWORD '${4}';" || return 1
            "${PSQL_BIN}" -h "${1}" -p "${2}" -U "${3}" -d postgres -q -c "ALTER USER ${USER} VALID UNTIL 'infinity';" || return 1
        done
    fi

    # Check if we should perform some transformations on table data
    if [ ! "${5}" = "!" ]; then
        if ! test_file_exists "${5}"; then log true "${SCRIPT_NAME}: Error! Command file '${5}' not found. Aborting."; return 1; fi

        # Iterate over lines in command file and apply basic transformations to table data
        # Expected format of each line: 'db_name:sql_command;' (without the single quotes). Example:
        # mydb:UPDATE users SET email = 'dummy@example.com';
        log "${SCRIPT_NAME}: Applying transformations to table data..."
        while IFS=: read -r DB CMD; do
            "${PSQL_BIN}" -h "${1}" -p "${2}" -U "${3}" -d ${DB} -q -c "${CMD}" || return 1
        done < "${5}"
    fi

    return 0
}

function do_export ()
{
    # Perform any pre-processing before exporting
    if ! do_processing "${3}" "${4}" "${5}" "${6}" "${7}"; then return 1; fi

    # Dump cluster roles
    log "${SCRIPT_NAME}: Dumping cluster roles..."
    "${PGDUMPALL_BIN}" -g --quote-all-identifiers --clean --if-exists -h "${3}" -p "${4}" -U "${5}" | sed -e '/^--/d' > "${1}/roles.sql"
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

    chmod 600 "${1}/roles.sql" || return 1

    # Get list of databases to dump (exclude postgres, template0 and template1)
    DATABASES=$("${PSQL_BIN}" -h "${3}" -p "${4}" -U "${5}" -d postgres -q -A -t -c "SELECT datname FROM pg_database WHERE datname !='template0' AND datname !='template1' AND datname !='postgres'")

    # Check there were no errors
    if [ $? -ne 0 ]; then return 1; fi

    # Verify we have a valid list
    if ! test_var ${DATABASES}; then log true "${SCRIPT_NAME}: Error! No database(s) found. Aborting."; return 1; fi

    # Dump databases
    NUM_DATABASES=${#DATABASES[@]}
    for DB in ${DATABASES[@]}; do
        log "${SCRIPT_NAME}: Dumping database '${DB}'..."

        mkdir "${1}/${DB}" || return 1

        chmod 700 "${1}/${DB}" || return 1

        "${PGDUMP_BIN}" -s --quote-all-identifiers --clean --if-exists -h "${3}" -p "${4}" -U "${5}" -d "${DB}" | sed -e '/^--/d' > "${1}/${DB}/schema.sql"
        if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

        chmod 600 "${1}/${DB}/schema.sql"

        "${PGDUMP_BIN}" --quote-all-identifiers --no-unlogged-table-data --data-only --encoding=UTF-8 -h "${3}" -p "${4}" -U "${5}" -d "${DB}" 2>/dev/null | sed -e '/^--/d' > "${1}/${DB}/data.sql"
        if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

        chmod 600 "${1}/${DB}/data.sql"
    done

    # Tar and compress (Note: --transform 's/^\.\///' is not supported by BSD tar, use -s '/.//' instead)
    touch "${1}/${2}" || return 1
    "${TAR_BIN}" --exclude="${2}" --transform 's/^\.\///' -cf - -C "${1}" . | "${GZIP_BIN}" -q -${GZIP_COMPRESSION} > "${1}/${2}"

    # Check there were no errors
    if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then return 1; fi

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
    if ! test_dir_is_writeable "${4}"; then log true "${SCRIPT_NAME}: Error! Export directory '${4}' does not exist (or is not writeable). Aborting."; exit ${E_EXPORT}; fi

    # Create temporary workspace
    WORKSPACE="${WORKSPACE_PATH_PREFIX}$(od -N 8 -t uL -An /dev/urandom | sed 's/\s//g')"
    create_workspace "${WORKSPACE}" || exit ${E_WORKSPACE}

    # Set export file name (with or without ISO 8601 timestamp)
    if [ ${9} = "true" ]; then EXPORT_FILE="${5}.$(date +%Y-%m-%dT%H-%M-%S).tar.gz"; else EXPORT_FILE="${5}.tar.gz"; fi

    # Import basebackup
    do_import "${SOURCE_FILE}" "${3}" || exit ${E_IMPORT}

    # Export raw sql as a gzip compressed tar archive
    do_export "${WORKSPACE}" "${EXPORT_FILE}" "${10}" "${11}" "${12}" "${13}" "${14}" || exit ${E_DUMP}

    # Secure the export
    chown ${6} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}
    chgrp ${7} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}
    chmod ${8} "${WORKSPACE}/${EXPORT_FILE}" || exit ${E_PKG}

    # Move to destination
    log "${SCRIPT_NAME}: Moving compressed export to '${4}/${EXPORT_FILE}'"
    mv "${WORKSPACE}/${EXPORT_FILE}" "${4}/${EXPORT_FILE}" || exit ${E_PKG}

    # Remove temporary workspace
    rm -rf "${WORKSPACE}" || exit ${E_WORKSPACE}

    log "${SCRIPT_NAME}: Converion complete (took $(($(date +%s)-${START_TIME})) seconds)"
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse and verify command line options
OPTSPEC=":hs:f:i:e:n:o:g:m:t:a:p:u:x:z:"
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
        a)
            PGSQL_HOST=${OPTARG}
            ;;
        p)
            PGSQL_PORT=${OPTARG}
            ;;
        u)
            PGSQL_USER=${OPTARG}
            ;;
        x)
            NEW_PASSWORD="${OPTARG}"
            ;;
        z)
            PRE_PROCESS_CMD_FILE="${OPTARG}"
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -s source_dir -f source_file_prefix -i import_dir -e export_dir -n export_file_prefix -o export_owner -g export_group -m export_file_mode -t true|false -a intermediary_pgsql_host -p intermediary_pgsql_port -u intermediary_pgsql_super_user [-x new_password] [-z path_to_pre_process_cmd_file]"
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
if ! test_var ${EXPORT_FILE_PREFIX}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_OWNER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_GROUP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE_MODE}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${EXPORT_FILE_TIMESTAMP}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_HOST}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_PORT}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${PGSQL_USER}; then echo "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi

# Check if we should reset ALL user account passwords
if ! test_var ${NEW_PASSWORD}; then NEW_PASSWORD="!"; fi

# Check if we should apply any pre processing/sanitising commands prior to exporting (e.g. to remove senstivie user info like email addresses)
if ! test_var ${PRE_PROCESS_CMD_FILE}; then PRE_PROCESS_CMD_FILE="!"; fi

# Perform conversion
do_conversion "${SOURCE_DIR}" "${SOURCE_FILE_PREFIX}" "${IMPORT_DIR}" "${EXPORT_DIR}" "${EXPORT_FILE_PREFIX}" "${EXPORT_OWNER}" "${EXPORT_GROUP}" ${EXPORT_FILE_MODE} ${EXPORT_FILE_TIMESTAMP} "${PGSQL_HOST}" "${PGSQL_PORT}" "${PGSQL_USER}" "${NEW_PASSWORD}" "${PRE_PROCESS_CMD_FILE}"

exit 0
