#!/bin/sh

BASE_URL=https://boot.ipxe.org
OUT_DIR=./tftp

# This script gets the listing from the main index from the above and
# then recreates the directory/file structure in the tftp directory

FILES=$(curl ${BASE_URL} | grep NORM | awk -F\" '{print $4;}')

for f in ${FILES} 
do
  echo $f
  d=${OUT_DIR}/$(dirname $f)
  mkdir -p $d
  curl ${BASE_URL}/$f -o ${OUT_DIR}/$f
done
