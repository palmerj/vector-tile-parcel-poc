# LINZ Parcels Tegola Vector Tile POC

This repo contains a simple Docker Compose configuration for orchestrating a basic installation of [Tegola](https://github.com/go-spatial/tegola) with PostGIS loaded with LDS parcels and topo roads/coastlines dataset for context

## Usage

Make sure you have defined and set the LDS_API_KEY variable in `.env` file using an API key from https://data.linz.govt.nz/my/api/ (sign up first). Also make sure the API key has a export scope defined.

To build the images:

docker-compose build

To run:

docker-compose up -d

To stop:

docker-compose stop
