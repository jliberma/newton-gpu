#!/bin/bash

time exec openstack overcloud deploy \
        --templates /usr/share/openstack-tripleo-heat-templates \
	-e /home/stack/templates/global-config.yaml \
        --environment-directory /home/stack/templates/environments
