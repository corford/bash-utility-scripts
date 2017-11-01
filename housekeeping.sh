#!/bin/bash
#
# Finds all files in a directory whose names begin with a given prefix and deletes
# them if they are older than N days (designed to be run daily by cron and used for
# cleaning up files e.g. old database backups)
#
# Note 1: For safety, this script only operates on files. It will not recursively
# walk through sub-directories.
#
# Note 2: Script uses a file's last modified time (mtime) as reported by the file
# system to determine age.
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
E_DELETE=3


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

function do_housekeeping ()
{
    log "${SCRIPT_NAME}: Starting housekeeping..."

    # Verify dir exists and is writeable
    if ! test_dir_is_writeable "${1}"; then log true "${SCRIPT_NAME}: Error! Directory '${1}' does not exist (or is not writeable). Aborting."; exit ${E_DELETE}; fi

    # Loop through files, deleting ones older than the threshold
    UNIX_TIME_NOW=$(date +%s)
    DELETED=0
    for FILE in $(find "${1}" -maxdepth 1 -type f -name "${2}*" -printf '%f\n');
    do
        FILE_MTIME=$(stat --printf=%Y "${1}/${FILE}")

        if [ $((${UNIX_TIME_NOW} - ${FILE_MTIME})) -gt $(((86400 * ${3})-1)) ]; then
            log "${SCRIPT_NAME}: Deleting '${FILE}' (file older than ${3} days)"
            rm "${1}/${FILE}" || exit ${E_DELETE}
            DELETED=1
        fi

    done

    if [ ${DELETED} -eq 0 ]; then
        log "${SCRIPT_NAME}: No files older than ${3} day(s) found. Nothing deleted."
    fi
}


# ////////////////////////////////////////////////////////////////////
# SCRIPT STARTS HERE
# ////////////////////////////////////////////////////////////////////

# Parse command line options
OPTSPEC=":hd:p:a:"
while getopts "${OPTSPEC}" OPT; do
    case ${OPT} in
        d)
            SOURCE_DIR=$(echo "${OPTARG}" | sed -e "s/\/*$//")
            ;;
        p)
            FILE_PREFIX="${OPTARG}"
            ;;
        a)
            MAX_AGE=${OPTARG}
            ;;
        h)
            echo ""
            echo "Usage: ${SCRIPT_NAME} -d source_dir -p file_prefix -a max_age_in_days"
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
if ! test_var ${SOURCE_DIR}; then echo -e "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${FILE_PREFIX}; then echo -e "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi
if ! test_var ${MAX_AGE}; then echo -e "${E_MSG}" >&2; exit ${E_MISSING_ARG}; fi


# Remove old files
do_housekeeping "${SOURCE_DIR}" "${FILE_PREFIX}" ${MAX_AGE}

exit 0
