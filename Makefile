include .env
export

download-wikidata:
# Download the latest wikidata dump if it doesn't exist or if a newer one is available. 
# Dumps are saved to the project temp volume. Interrupted downloads are continued.
	docker run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		byrnedo/alpine-curl \
			--retry 10 \
			--retry-delay 60 \
			-SL -C - https://dumps.wikimedia.org/wikidatawiki/entities/latest-all.ttl.gz \
			--time-cond /var/tmp/latest-all.ttl.gz \
			-o /var/tmp/latest-all.ttl.gz

prep-wikidata:
# Pre-process the wikidata RDF dump into ttls for loading. Requires `download-wikidata` to have completed first.
	docker-compose run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		--entrypoint ./munge.sh \
		wdqs -f /var/tmp/latest-all.ttl.gz \
		-d /var/tmp/ttls 

import-wikidata:
# Load processed data from the `prep-wikidata` function into Blazegraph. 
# Requires the wdqs service to be running (e.g. `docker-compose up -d`).
	docker-compose exec wdqs loadRestAPI.sh -n wdq -h http://wdqs:9999 -d /var/tmp/ttls

download-osm:
# Download the latest OpenStreetMap data if it doesn't exist or if a newer one is available.
# OSM data is saved to the project temp volume. Interrupted downloads are continued.

# TODO curl bug returns FTP transient problem if file already exists.
# See https://github.com/curl/curl/issues/2464
	docker run \
		-v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		byrnedo/alpine-curl \
			--retry 10 \
			--retry-delay 60 \
			-SL -C - https://download.geofabrik.de/europe/albania-latest.osm.pbf \
			--time-cond /var/tmp/latest-all.ttl.gz \
			-o /var/tmp/albania-latest.osm.pbf

prep-osm: 
# Convert OSM Planet into import files (ttls)
	docker run -it -v $(COMPOSE_PROJECT_NAME)_temp_data:/var/tmp \
		-v $(COMPOSE_PROJECT_NAME)_wdqs_data:/var/lib/wdqs \
		osm2rdf -c /var/lib/wdqs/wd_nodes.cache \
			-s dense parse /var/tmp/albania-latest.osm.pbf /var/tmp/ttls 

wikidata-all: download-wikidata prep-wikidata download-osm prep-osm import-wikidata
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

import-osm:
# Import OSM Planet file into PostgreSQL. Must run `download-osm` first.
	docker run -it --env-file .env \
		--network=$(COMPOSE_PROJECT_NAME)_postgres_conn \
		-e OSM2PGSQL_VERSION=0.96.0 \
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
		--create --slim --database gis --flat-nodes /var/lib/wdqs/rgn_nodes.cache \
		-C 26000 --number-processes 8 --hstore --style /var/lib/osm2pgsql/wikidata.style \
		--tag-transform-script /var/lib/osm2pgsql/wikidata.lua \
		/var/tmp/albania-latest.osm.pbf

#TODO Wait for docker-compose up (./wait-for-it.sh?)	
#osm-all: download-osm clean-osm import-osm
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

