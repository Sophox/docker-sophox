include .env
export

.NOTPARALLEL: wikidata-all osm-all

all: wikidata-all osm-all

download-wikidata:
# Download the latest wikidata dump if it doesn't exist. 
# Dumps are saved to the project temp volume. Interrupted downloads are continued.
	docker run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		byrnedo/alpine-curl \
			--retry 10 \
			--retry-delay 60 \
			-SL -C - https://dumps.wikimedia.org/wikidatawiki/entities/latest-all.ttl.gz \
			-o /var/tmp/latest-all.ttl.gz

prep-wikidata:
# Pre-process the wikidata RDF dump into ttls for loading. 
# Requires `download-wikidata` to have completed first.
	docker-compose run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		--entrypoint ./munge.sh \
		wdqs -f /var/tmp/latest-all.ttl.gz \
		-d /var/tmp/ttls 

start-blazegraph:
	docker-compose up -d wdqs

start-postgres:
	docker-compose up -d postgres

import-wikidata: start-blazegraph
# Load processed data from the `prep-wikidata` function into Blazegraph. 
# Requires the wdqs service to be running (e.g. `docker-compose up -d`).
	docker-compose exec wdqs loadRestAPI.sh -n wdq -h http://wdqs:9999 -d /var/tmp/ttls

download-osm: init-osm-replication
# Download the latest OpenStreetMap data if it doesn't exist.
# OSM data is saved to the project temp volume. Interrupted downloads are continued.

# TODO curl bug returns FTP transient problem if file already exists.
# See https://github.com/curl/curl/issues/2464
	docker run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		-w /var/tmp \
		byrnedo/alpine-curl \
			--retry 10 \
			--retry-delay 60 \
			-SL -C - \
			http://download.openstreetmap.fr/extracts/europe/france{-latest.osm.pbf,.state.txt} \
			-o france-latest.osm.pbf -o /var/lib/wdqs/geosync_workdir/state.text

prep-osm: 
# Convert OSM Planet into import files (ttls)
	docker run -it -v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		osm2rdf -c /var/lib/wdqs/wd_nodes.cache \
			-s dense parse /var/tmp/france-latest.osm.pbf /var/tmp/ttls

download-files: download-wikidata download-osm

prep-files: prep-osm prep-wikidata

wikidata-all: download-files prep-files
# Downloads, processes, and imports wikidata dump into Blazegraph.
# WARNING: This may take a long time and will overwrite existing data.

clean-osm:
# Turn off all services and remove the postgres_data volume. 
# The postgres_data volume gets recreated on docker-compose up.
# There may be a better way to do this.
#
# This sort of works, but doesn't recreate the extensions.
# DROP SCHEMA public;
# CREATE SCHEMA public;
	docker-compose down \
		&& docker volume rm -f $(COMPOSE_PROJECT_NAME)_postgres_data \
		&& docker-compose up -d

init-osm-replication:
	docker run -v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		--name helper alpine 
	docker cp ./geosync_workdir helper:/var/lib/wdqs
	docker rm helper

import-osm: start-postgres
# Import OSM Planet file into PostgreSQL. Must run `download-osm` first.
	docker run -it --env-file .env \
		--network=$(COMPOSE_PROJECT_NAME)_postgres_conn \
		-e OSM2PGSQL_VERSION=$(OSM2PGSQL_VERSION) \
		-e PGHOST=$(POSTGRES_HOST) \
		-e PGPORT=$(POSTGRES_PORT) \
		-e PGUSER=$(POSTGRES_USER) \
		-e PGPASSWORD=$(POSTGRES_PASSWORD) \
		-e PGDATABASE=$(POSTGRES_DB) \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		-v $(shell pwd):/var/lib/osm2pgsql \
		--entrypoint osm2pgsql \
		openfirmware/osm2pgsql \
		--create --slim --database $(POSTGRES_DB) --flat-nodes /var/lib/wdqs/rgn_nodes.cache \
		-C 26000 --number-processes 8 --hstore --style /var/lib/osm2pgsql/wikidata.style \
		--tag-transform-script /var/lib/osm2pgsql/wikidata.lua \
		/var/tmp/france-latest.osm.pbf

create-indexes:
	docker run -it --env-file .env --network=$(COMPOSE_PROJECT_NAME)_postgres_conn \
	-e PGHOST=$(POSTGRES_HOST) \
	-e PGPORT=$(POSTGRES_PORT) \
	-e PGUSER=$(POSTGRES_USER) \
	-e PGPASSWORD=$(POSTGRES_PASSWORD) \
	-e PGDATABASE=$(POSTGRES_DB) \
	postgres:9.6 psql -c "CREATE INDEX IF NOT EXISTS planet_osm_point_wikidata ON planet_osm_point (wikidata); CREATE INDEX IF NOT EXISTS planet_osm_line_wikidata ON planet_osm_line (wikidata); CREATE INDEX IF NOT EXISTS planet_osm_polygon_wikidata ON planet_osm_polygon (wikidata);"

#TODO Wait for docker-compose up (./wait-for-it.sh?)	
osm-all: download-osm import-osm create-indexes
# Downloads and imports OpenStreetMap data into PostgreSQL.
# WARNING: This may take a long time and will overwrite existing data.

psql:
	docker run -it --env-file .env --network=$(COMPOSE_PROJECT_NAME)_postgres_conn \
	-e PGHOST=$(POSTGRES_HOST) \
	-e PGPORT=$(POSTGRES_PORT) \
	-e PGUSER=$(POSTGRES_USER) \
	-e PGPASSWORD=$(POSTGRES_PASSWORD) \
	-e PGDATABASE=$(POSTGRES_DB) \
	postgres:9.6 psql

dev:
	docker run -it -v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		-v $(COMPOSE_PROJECT_NAME)_postgres_data:/var/lib/postgresql/data \
		alpine sh

