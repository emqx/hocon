#!/bin/bash

set -uo pipefail

curl -OL https://github.com/henrikno/hoc2js/releases/download/v1.1-fix/hoc2js-1.1-fix.jar

mkdir -p sample-configs/json
for conf in sample-configs/*.conf; do
  basename "$conf"
  if [[ "$conf" = *"test01.conf" ]]; then
    echo skipping test01.conf, as it reveals your home directory
  else
    java -jar hoc2js-1.1-fix.jar < "$conf" > "sample-configs/json/$(basename "$conf").json"
  fi
done

