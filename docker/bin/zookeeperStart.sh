#!/usr/bin/env bash
#
# Copyright (c) 2018 Dell Inc., or its subsidiaries. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

set -ex
# SLEEP=20
# echo "Wait ${SLEEP} sec for CM update, if any"
# sleep ${SLEEP}

source /conf/env.sh
source /usr/local/bin/zookeeperFunctions.sh

# OFFSET=4
# CLIENT_HOST=zk1-0.zk1-headless.ns-team-aep-pipeline-kafka-1-dev
# CLIENT_PORT=2181
# MIGRATION_MODE=0|1
# FQDN_TEMPLATE=

HOST=`hostname -s`
DATA_DIR=/data
MYID_FILE=$DATA_DIR/myid
LOG4J_CONF=/conf/log4j-quiet.properties
DYNCONFIG=$DATA_DIR/zoo.cfg.dynamic
STATIC_CONFIG=/data/conf/zoo.cfg

# Extract resource name and this members ordinal value from pod hostname
if [[ $HOST =~ (.*)-([0-9]+)$ ]]; then
    NAME=${BASH_REMATCH[1]}
    ORD=${BASH_REMATCH[2]}
else
    echo Failed to parse name and ordinal of Pod
    exit 1
fi

OFFSET=${OFFSET:-1}
MIGRATION_MODE=${MIGRATION_MODE:-0}
FQDN_TEMPLATE=${FQDN_TEMPLATE:-$CLIENT_HOST}
CLIENT_HOST=${SEED_NODE:-$CLIENT_HOST}
MYID=$(($ORD+$OFFSET))
FIRST_NODE=$OFFSET

if [ $MIGRATION_MODE -eq 1 ]; then
  OUTSIDE_NAME=$(echo ${FQDN_TEMPLATE} | sed "s/%/$(($ORD+1))/g")
fi

# Values for first startup
WRITE_CONFIGURATION=true
REGISTER_NODE=true
ONDISK_MYID_CONFIG=false
ONDISK_DYN_CONFIG=false

# Check validity of on-disk configuration
if [ -f $MYID_FILE ] && [ -f $STATIC_CONFIG ]; then
  MYID=$(cat $MYID_FILE)
  ONDISK_MYID_CONFIG=true
  
  # 4 5 6
  # 1 2 3
  if [ -f $DATA_DIR/migration_mode ]; then
    MIGRATION_MODE_STATUS=$(cat $DATA_DIR/migration_mode)
    if [ -n $MIGRATION_MODE_STATUS ] && [ $MIGRATION_MODE_STATUS -ne 0 ] && [ $MIGRATION_MODE_STATUS -ne $MIGRATION_MODE ]; then
      MYID=$(($ORD+$OFFSET))
      echo $MYID > $MYID_FILE
      ONDISK_MYID_CONFIG=false
      FIRST_NODE=3
    fi
  fi
fi

if [ -f $DYNCONFIG ]; then
  ONDISK_DYN_CONFIG=true
fi

set +e
# Check if envoy is up and running
if [[ -n "$ENVOY_SIDECAR_STATUS" ]]; then
  COUNT=0
  MAXCOUNT=${1:-30}
  HEALTHYSTATUSCODE="200"
  while true; do
    COUNT=$(expr $COUNT + 1)
    SC=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:15000/ready)
    echo "waiting for envoy proxy to come up";
    sleep 1;
    if (( "$SC" == "$HEALTHYSTATUSCODE" || "$MAXCOUNT" == "$COUNT" )); then
      break
    fi
  done
fi
set -e

# Determine if there is an ensemble available to join by checking the service domain
set +e
nc -v -w2 $CLIENT_HOST $CLIENT_PORT  # This only performs a dns lookup
if [[ $? -ne 0 ]]; then
  ACTIVE_ENSEMBLE=false
else
  ACTIVE_ENSEMBLE=true
fi

if [[ "$ONDISK_MYID_CONFIG" == true && "$ONDISK_DYN_CONFIG" == true ]]; then
  # If Configuration is present, we assume, there is no need to write configuration.
    WRITE_CONFIGURATION=false
else
    WRITE_CONFIGURATION=true
fi

if [[ "$ACTIVE_ENSEMBLE" == false ]]; then
  # This is the first node being added to the cluster or headless service not yet available
  REGISTER_NODE=false
else
  REGISTER_NODE=true
fi

if [[ "$WRITE_CONFIGURATION" == true ]]; then
  echo "Writing myid: $MYID to: $MYID_FILE."
  echo $MYID > $MYID_FILE
  if [[ $MYID -eq $FIRST_NODE ]]; then
    ROLE=participant
    echo Initial initialization of ordinal 0 pod, creating new config.
    ZKCONFIG=$(zkConfig ${OUTSIDE_NAME})
    echo Writing bootstrap configuration with the following config:
    echo $ZKCONFIG
    echo $MYID > $MYID_FILE
    echo "server.${MYID}=${ZKCONFIG}" > $DYNCONFIG
  fi
fi

if [[ "$REGISTER_NODE" == true ]]; then
    ROLE=observer
    ZKURL=$(zkConnectionString)
    ZKCONFIG=$(zkConfig ${OUTSIDE_NAME})
    set -e
    echo Registering node and writing local configuration to disk.
    java -Dlog4j.configuration=file:"$LOG4J_CONF" -jar /root/zu.jar add $ZKURL $MYID  $ZKCONFIG $DYNCONFIG
    # ZKCONFIG=$(zkConfig)
    # sed -i "s|server.${MYID}=.*|server.${MYID}=${ZKCONFIG}|g" $DYNCONFIG
    set +e
fi

ZOOCFGDIR=/data/conf
export ZOOCFGDIR
echo Copying /conf contents to writable directory, to support Zookeeper dynamic reconfiguration
if [[ ! -d "$ZOOCFGDIR" ]]; then
  mkdir $ZOOCFGDIR
fi
# safe to do only with register node/active ensamble
cp -f /conf/zoo.cfg $ZOOCFGDIR

cp -f /conf/log4j.properties $ZOOCFGDIR
cp -f /conf/log4j-quiet.properties $ZOOCFGDIR
cp -f /conf/env.sh $ZOOCFGDIR

echo $MIGRATION_MODE > $DATA_DIR/migration_mode

echo "Static config"
cat $STATIC_CONFIG

echo "Dynamic config"
cat $DYNCONFIG

echo "Real dynamic config"
cat $(grep -i dynamicConfigFile $STATIC_CONFIG | cut -f 2 -d "=")

if [ -f $DYNCONFIG ]; then
  # Node registered, start server
  echo Starting zookeeper service
  zkServer.sh --config $ZOOCFGDIR start-foreground
else
  echo "Node failed to register!"
  exit 1
fi
