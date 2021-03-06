# bash-utility-scripts
Collection of reasonably robust and portable bash scripts (mainly for backing up postgresql and redis).

All scripts are designed to play nice with cron (you can safely redirect stdout to /dev/null and still
get proper error codes and alerts if something goes wrong; including with piped commands). All destination
files are atomically moved in to postion (so e.g. dev users don't accidentally pickup corrupted archvies
while snapshots are being created).

An effort has been made to use portable bash commands that should work on most GNU/BSD systems (although
they have really only been tested on Linux).

Each script has an -h flag that will show you what commands it requires and contains a description at the top
of the script file itself.

# Typical workflows:
Use `pgsql-backup-wrapper.sh` to take a pg_basebackup of a running postgres cluster and ship a GPG encrypted
copy somewhere safe (e.g. https://rsync.net)

Use `pgsql-base-backup-convert.sh` to convert the previously taken basebackup to raw SQL and optionally change
role passwords and sanitise table data (useful for preparing an archive from a basebackup that can be pulled
down by your developers)

Use `pgsql-simple-backup.sh` to take a pg_dump backup of a cluster (with or without table data).

Use `pgsql-sanitise-backup.sh` against pg_dumpall produced role files to reset all cluster passwords to
a given string (again, useful for preparing bootstrap archives for dev machines that shouldn't see prod
credentials)

Use `pgsql-wal-archive.sh` as a drop-in WAL archiving script for sending WAL files to a remote host (thanks to
an LFTP trick, it follows the postgres docs recommendation and safely refuses to overwrite any pre-existing
archive file)

Use `redis-backup-wrapper.sh` to take a snapshot of a running redis instance and ship a GPG encrypted copy
somehwere safe. Script guarantees a flushed snapshot by running BGSAVE on the instance prior to backup.

Use `mirror-to-offsite.sh` as a generic way to mirror files & dirs (rsync style) to a remote host. Supports
bandwidth limiting and works even for remote sftp only jails that don't support rsync.

Use `housekeeping.sh` to automatically clean up local copies of backups produced by the scripts above (once they have been encrypted and shipped off-site).

