#!/bin/bash
#
# Copyright (c) 2017 Alexander Trost
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

function join {
	local IFS="$1"
	shift
	joined=$(tr "$IFS" '\n' <<< "$*" | sort -un | tr '\n' "$IFS")
	echo "${joined%?}"
}

if [ -n "$DEBUG" ]; then
    set -x
fi

# Extra Galera/MySQL setting envs
wsrep_slave_threads="${WSREP_SLAVE_THREADS:-2}"

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

if [ -z "$CLUSTER_NAME" ]; then
	echo >&2 'Error: You need to specify CLUSTER_NAME'
	exit 1
fi
if [ -z "$DISCOVERY_SERVICE" ]; then
	echo >&2 'Error: You need to specify DISCOVERY_SERVICE'
	exit 1
fi

set -e
# Get config
DATADIR="$(mysqld --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }' | sed 's#/$##')"
if [ ! -e "$DATADIR/init.ok" ]; then
	if [ -z "$MYSQL_ROOT_PASSWORD" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ] && \
		[ -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        echo >&2 'Error: Database is uninitialized and password option is not specified '
        echo >&2 '       You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
        exit 1
    fi
	mkdir -p "$DATADIR"
	echo "-> Running mysqld --initialize to $DATADIR"
	ls -lah "$DATADIR"
	mysqld --initialize --datadir="$DATADIR"
	chown -R mysql:mysql "$DATADIR"
	chown mysql:mysql /var/log/mysqld.log
	echo "=> Finished mysqld --initialize"
	tempSqlFile='/tmp/mysql-first-time.sql'
	echo "" > "$tempSqlFile"
	set -- "$@" --init-file="$tempSqlFile"
	if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		MYSQL_ROOT_PASSWORD="$(pwmake 128)"
		echo
		echo "======================================================"
		echo "==> GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD <=="
		echo "======================================================"
		echo
	fi
	cat >> "$tempSqlFile" <<-EOSQL
		-- What's done in this file shouldn't be replicated
		--  or products like mysql-fabric won't work
		SET @@SESSION.SQL_LOG_BIN=0;
		CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
		GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
		ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
		CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
		GRANT RELOAD,PROCESS,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
		GRANT REPLICATION CLIENT ON *.* TO monitor@'%' IDENTIFIED BY 'monitor';
		GRANT PROCESS ON *.* TO monitor@localhost IDENTIFIED BY 'monitor';
		DROP DATABASE IF EXISTS test;
		FLUSH PRIVILEGES;
	EOSQL
	# sed is for https://bugs.mysql.com/bug.php?id=20545
	echo "$(mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/')" >> "$tempSqlFile"
	if [ "$MYSQL_DATABASE" ]; then
		echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;" >> "$tempSqlFile"
	fi
	if [ "$MYSQL_USER" ] && [ "$MYSQL_PASSWORD" ]; then
		echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> "$tempSqlFile"
		if [ "$MYSQL_DATABASE" ]; then
			echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';" >> "$tempSqlFile"
		fi
		echo 'FLUSH PRIVILEGES;' >> "$tempSqlFile"
	fi
	if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
		echo "ALTER USER 'root'@'%' PASSWORD EXPIRE;" >> "$tempSqlFile"
	fi
	echo
	echo '=> MySQL first time init preparation done. Ready for start up.'
	echo
fi
touch $DATADIR/init.ok
chown -R mysql:mysql "$DATADIR"

echo
echo '-> Registering in the discovery service ...'
echo

set +e
# Read the list of registered IP addresses
ipaddr="$(hostname -i | awk '{ print $1 }')"
hostname="$(hostname)"

curl "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/queue/$CLUSTER_NAME" -XPOST -d value="$ipaddr" -d ttl=60
# get list of IP from queue
ips1=$(curl "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/queue/$CLUSTER_NAME" | jq -r '.node.nodes[].value')

# Register the current IP in the discovery service
# key set to expire in 30 sec. There is a cronjob that should update them regularly
curl http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr/ipaddr -XPUT -d value="$ipaddr" -d ttl=30
curl http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr/hostname -XPUT -d value="$hostname" -d ttl=30
curl http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr -XPUT -d ttl=30 -d dir=true -d prevExist=true
set -e
echo
echo "=> Registered with discovery service."
echo
set +e

ips2=""
c=1
while (( c<=6 )) && [ -z "$ips2" ]; do
	ips2=$(curl "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/?quorum=true" | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
	echo "-> No peers found in discovery. Trying again in 3 seconds ..."
	sleep 3
	(( c++ ))
done
echo "=> Found peers in discovery."
# this remove my ip from the list
cluster_join="$(join , "${ips1[@]/$ipaddr}" "${ips2[@]/$ipaddr}")"
/usr/bin/clustercheckcron "monitor" monitor 1 /var/lib/mysql/clustercheck.log 1 "/etc/mysql/my.cnf" &
set -e

echo
echo "-> Joining cluster $cluster_join ..."
echo

cat > /etc/mysql/conf.d/wsrep.cnf <<EOF
[mysqld]

user = mysql
datadir=/var/lib/mysql

log_error = "${DATADIR}/error.log"

default_storage_engine=InnoDB
binlog_format=ROW

innodb_flush_log_at_trx_commit = 0
innodb_flush_method            = O_DIRECT
innodb_file_per_table          = 1
innodb_autoinc_lock_mode       = 2

bind_address = 0.0.0.0

wsrep_slave_threads = $wsrep_slave_threads
wsrep_cluster_address = gcomm://$cluster_join
wsrep_provider = /usr/lib/galera3/libgalera_smm.so
wsrep_node_address = $ipaddr

wsrep_cluster_name="$CLUSTER_NAME"

wsrep_sst_method = xtrabackup-v2
wsrep_sst_auth = "xtrabackup:$XTRABACKUP_PASSWORD"
EOF

exec "$@"