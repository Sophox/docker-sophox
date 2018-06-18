#!/bin/bash

export PGHOST=$POSTGRES_HOST 
export PGPORT=$POSTGRES_PORT 
export PGUSER=$POSTGRES_USER
export PGPASSWORD=$POSTGRES_PASSWORD
export PGDATABASE=$POSTGRES_DB

while :; do
    osmosis --read-replication-interval workingDirectory=/var/lib/wdqs/geosync_workdir \
    --simplify-change --write-xml-change - | osm2pgsql --append --slim \
    --database $POSTGRES_DB --flat-nodes /var/lib/wdqs/rgn_nodes.cache \
	-C 26000 --number-processes 8 --hstore --style /var/lib/osm2pgsql/wikidata.style \
	--tag-transform-script /var/lib/osm2pgsql/wikidata.lua -r xml -
    [ $LOOP -eq 0 ] && exit $?
    sleep $LOOP || exit 
done