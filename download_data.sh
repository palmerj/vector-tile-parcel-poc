#!/bin/bash

# Quick script to download LDS data and prepare it for loading into
# a POSTGIS Database
endpoint="https://data.linz.govt.nz/services/api/v1/exports/"
download_file="nz-data.zip"
poll_interval=10

if [ -z "$LDS_API_KEY" ]
then
    echo "LDS_API_KEY environment variable is not set"
    exit
fi

# Export json config for NZ Parcels, Topo50 Roads, Topo Coastline
# In Web mercator projection, full extent
# Use FileGDB format as it's the most compact file format

# Wellington geojson extent to limit dataset. Remove extent attribute 
# for full dataset
export_json=$(cat <<'EOF'
{ 
    "crs":"EPSG:3857",
    "formats":{
        "vector":"applicaton/x-ogc-filegdb"
    },
    "extent": {
        "type": "Polygon",
        "coordinates": [
            [
                [174.59678649902344,-41.068480785991646],
                [174.52880859375,-41.38865810163063],
                [175.07675170898438,-41.50343510361136],
                [175.1818084716797,-41.25871065195755],
                [175.1227569580078,-41.107812630002144],
                [174.90371704101562,-41.01410200926009],
                [174.59678649902344,-41.068480785991646]
            ]
        ]
    },
    "items":[
        {
            "item":"https://data.linz.govt.nz/services/api/v1/layers/51571/"
        },
        {
            "item":"https://data.linz.govt.nz/services/api/v1/layers/51153/"
        },
        {
            "item":"https://data.linz.govt.nz/services/api/v1/layers/50329/"
        }
    ]
}
EOF
)

echo "Starting export"
http_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST $endpoint \
    -H "content-type:application/json" \
    -H "Authorization: key $LDS_API_KEY" \
    -d "$export_json"
)
http_status=$(echo $http_response | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
http_body=$(echo $http_response | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
if [[ "$http_status" -ne 201 ]] ; then
    echo "Error: HTTP status code $http_status: $http_body"
    exit 1
fi
export_url=$(echo $http_response | tr -d '\n' \
    | awk 'BEGIN { FS="\""; RS="," }; { if ($2 ~ /^url$/ && $4 ~ /exports/) {print $4} }'
)
echo "Export created: $export_url"
while true; do
    status=$(curl --silent $export_url \
        -H "content-type:application/json" \
        -H "Authorization: key $LDS_API_KEY" \
        | awk 'BEGIN { FS="\""; RS="," }; { if ($2 == "state") {print $4} }'
    )
    case $status in
        processing)
            sleep $poll_interval;
            ;;
        complete)
            echo "Export processing complete"
            break
            ;;
        *)
            echo "Download process state is $status. Exiting"
            exit 1
            ;;
    esac
done

download_url=$(curl --silent $export_url \
    -H "content-type:application/json" \
    -H "Authorization: key $LDS_API_KEY" \
    | awk 'BEGIN { FS="\""; RS="," }; { if ($2 == "download_url") {print $4} }'
)
if [ -z "$download_url" ]
then
    echo "download_url is not defined for export"
    exit 1
fi
echo "Starting export download for $download_url to $download_file"
curl --silent --output $download_file $download_url -H "Authorization: key $LDS_API_KEY"
echo "Download of $download_file complete"

unzip -q $download_file
rm -rf $download_file

ogr2ogr -f PGDump \
    --config PG_USE_COPY YES \
    -f PGDump /vsigzip/z01-nz-coastlines.sql.gz \
    -lco SCHEMA=nzdata \
    -lco GEOMETRY_NAME=shape \
    -lco SPATIAL_INDEX=NONE \
    -lco POSTGIS_VERSION=2.5 \
    -nln nz_topo50_coastline \
    nz-coastlines-and-islands-polygons-topo-150k/nz-coastlines-and-islands-polygons-topo-150k.gdb

ogr2ogr -f PGDump \
    --config PG_USE_COPY YES \
    -f PGDump /vsigzip/z02-nz-roads.sql.gz \
    -lco GEOMETRY_NAME=shape \
    -lco SPATIAL_INDEX=NONE \
    -lco SCHEMA=nzdata \
    -lco CREATE_SCHEMA=OFF \
    -lco POSTGIS_VERSION=2.5 \
    -lco FID=t50_fid \
    -nln nz_topo50_roads \
    nz-road-centrelines-topo-150k/nz-road-centrelines-topo-150k.gdb

ogr2ogr -f PGDump \
    --config PG_USE_COPY YES \
    -f PGDump /vsigzip/z03-nz-parcels.sql.gz \
    -lco GEOMETRY_NAME=shape \
    -lco SPATIAL_INDEX=NONE \
    -lco SCHEMA=nzdata \
    -lco CREATE_SCHEMA=OFF \
    -lco POSTGIS_VERSION=2.5 \
    -lco FID=id \
    -nln nz_parcels \
    nz-parcels/nz-parcels.gdb

# Create Indexes at the end. OGR was creating them before the data was loaded
# causing performance issues
cat <<EOF > z04-spatial-indexes.sql
CREATE INDEX nz_topo50_coastline_shape_geom_idx ON nzdata.nz_topo50_coastline USING GIST (shape);
CREATE INDEX nz_topo50_roads_shape_geom_idx ON nzdata.nz_topo50_roads USING GIST (shape);
CREATE INDEX nz_parcels_shape_geom_idx ON nzdata.nz_parcels USING GIST (shape);
EOF
