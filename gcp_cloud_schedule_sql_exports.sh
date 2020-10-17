#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2020-10-16 10:51:45 +0100 (Fri, 16 Oct 2020)
#
#  https://github.com/HariSekhon/pytools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/HariSekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
. "$srcdir/lib/utils.sh"

# shellcheck disable=SC2034,SC2154
usage_description="
Creates Cloud Scheduler PubSub jobs to trigger Cloud SQL export jobs for every database
in every running non-replica Cloud SQL instance in the current project

SQL instances can optionally be specified, otherwise iterates all running non-replica SQL instances
(only running instances can export, otherwise will error out)
(only non-replicas should be exported, replicas will likely fail due to conflict with replication recovery)

Optional environment variables and their defaults:

\$BUCKET                  \${project_id}-sql-backups
\$PUBSUB_TOPIC            cloud-sql-backups
\$CLOUD_SCHEDULER_CRON    0 2 * * *
\$TIMEZONE                Etc/UTC
\$CLOUD_SCHEDULER_REPLACE if set to any value will delete and recreate the Cloud Scheduler job (gcloud prompts before deleting each job)
"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="[<sql_instance1> <sql_instance2> ...]"

help_usage "$@"

no_more_opts "$@"

project_id="$(gcloud config list --format="value(core.project)")"
bucket="${BUCKET:-${project_id}-sql-backups}"
cron="${CLOUD_SCHEDULER_CRON:-0 2 * * *}"
topic="${PUBSUB_TOPIC:-cloud-sql-backups}"
timezone="${TIMEZONE:-Etc/UTC}"

sql_instances="$*"

if [ -z "$sql_instances" ]; then
    # XXX: can only list databases and export from running instances
    #      can only export from non-replicas (see gcp_sql_export.sh for details)
    timestamp "Getting all SQL instance in the current project"
    sql_instances="$(gcloud sql instances list --format=json |
                     jq -r '.[] | select(.instanceType != "READ_REPLICA_INSTANCE") | select(.state == "RUNNABLE") | .name')"
fi

for sql_instance in $sql_instances; do
    timestamp "Getting all databases on SQL instance '$sql_instance'"
    databases="$(gcloud sql databases list --instance="$sql_instance" --format='get(name)')"
    echo >&2
    for database in $databases; do
        job_name="cloud-sql-backup--$sql_instance--$database"
        if [ -n "${CLOUD_SCHEDULER_REPLACE:-}" ]; then
            timestamp "Deleting Cloud Scheduler job for instance '$sql_instance' database '$database' if exists"
            gcloud scheduler jobs delete "$job_name" || :
            echo >&2
        fi
        timestamp "Creating Cloud Scheduler job for instance '$sql_instance' database '$database'"
        gcloud scheduler jobs create pubsub "$job_name" --schedule "$cron" --topic "$topic" --message-body '{ "database": "'"$database"'", "instance": "'"${sql_instance}"'", "project": "'"$project_id"'", "bucket": "'"$bucket"'" }' --time-zone "$timezone" --description "Triggers Cloud SQL export of instance '$sql_instance' database '$database' via a PubSub message trigger to a Cloud Function"
        echo >&2
    done
done