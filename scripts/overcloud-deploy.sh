#!/bin/bash

exec openstack overcloud deploy \
  --templates /usr/share/openstack-tripleo-heat-templates \
  --timeout 90 \
  --verbose \
  -e /home/stack/templates/global-config.yaml \
  -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
  --environment-directory /home/stack/templates/environments
  --log-file /home/stack/overcloud-deploy.log
