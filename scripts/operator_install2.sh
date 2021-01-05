#!/bin/bash

################################################################################
# Copyright 2020 Armory, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

# Install Minnaker in Ubuntu VM (will first install k3s)

set -e

##### Functions
print_help () {
  set +x
  echo "Usage: install.sh"
  echo "               [-o|--oss]                                         : Install Open Source Spinnaker (instead of Armory Spinnaker)"
  echo "               [-P|--public-endpoint <PUBLIC_IP_OR_DNS_ADDRESS>]  : Specify public IP (or DNS name) for instance (rather than autodetection)"
  echo "               [-B|--base-dir <BASE_DIRECTORY>]                   : Specify root directory to use for manifests"
  echo "               [-n|--nowait]                                      : Don't wait for Spinnaker to come up"
  set -x
}

######## Script starts here

PROJECT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/../" >/dev/null 2>&1 && pwd )

OPEN_SOURCE=0
PUBLIC_ENDPOINT=""
MAGIC_NUMBER=cafed00d
DEAD_MAGIC_NUMBER=cafedead
KUBERNETES_CONTEXT=default
NAMESPACE=spinnaker
SPIN_WATCH=1                 # Wait for Spinnaker to come up

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "Use osx_install.sh to install on OSX Docker Desktop"
  exit 1
fi

BASE_DIR=/etc/spinnaker

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--oss)
      printf "Using OSS Spinnaker"
      OPEN_SOURCE=1
      ;;
    -x)
      printf "Excluding from Minnaker metrics"
      MAGIC_NUMBER=${DEAD_MAGIC_NUMBER}
      ;;
    -P|--public-endpoint)
      if [ -n $2 ]; then
        PUBLIC_ENDPOINT=$2
        shift
      else
        printf "Error: --public-endpoint requires an IP address >&2"
        exit 1
      fi
      ;;
    -B|--base-dir)
      if [ -n $2 ]; then
        BASE_DIR=$2
      else
        printf "Error: --base-dir requires a directory >&2"
        exit 1
      fi
      ;;
    -n|--nowait)
      printf "Will not wait for Spinnaker to come up"
      SPIN_WATCH=0
      ;;
    -h|--help)
      print_help
      exit 1
      ;;
  esac
  shift
done

. ${PROJECT_DIR}/scripts/functions.sh

if [[ ${OPEN_SOURCE} -eq 1 ]]; then
  printf "Using OSS Spinnaker"
  SPIN_FLAVOR=oss
  VERSION=$(curl -s https://spinnaker.io/community/releases/versions/ | grep 'id="version-' | head -1 | sed -e 's/\(<[^<][^<]*>\)//g; /^$/d' | cut -d' ' -f2)
else
  printf "Using Armory Spinnaker"
  SPIN_FLAVOR=armory
  VERSION=$(curl -sL https://halconfig.s3-us-west-2.amazonaws.com/versions.yml | grep 'version: ' | awk '{print $NF}' | sort | tail -1)
fi

echo "Running minnaker setup for Linux"
  
# Scaffold out directories
# OSS Halyard uses 1000; we're using 1000 for everything
sudo mkdir -p ${BASE_DIR}/.kube
sudo mkdir -p ${BASE_DIR}/.hal/.secret

detect_endpoint
generate_passwords

# Fix up operator manifests
SPINNAKER_PASSWORD=$(cat ${BASE_DIR}/.hal/.secret/spinnaker_password)
MINIO_PASSWORD=$(cat ${BASE_DIR}/.hal/.secret/minio_password)
ENDPOINT=$(cat ${BASE_DIR}/.hal/public_endpoint)

# Clone spinnaker-kustomize-patches
git clone https://github.com/armory/spinnaker-kustomize-patches.git ${BASE_DIR}/operator
cd ${BASE_DIR}/operator
rm kustomization.yml
ln -s recipes/kustomization-minnaker.yml kustomization.yml

sed -i "s|spinnaker.mycompany.com|${ENDPOINT}|g" expose/ingress-traefik.yml
sed -i "s|^http-password=xxx|http-password=${SPINNAKER_PASSWORD}|g" secrets/secrets-example.env
sed -i "s|^minioAccessKey=changeme|minioAccessKey=${MINIO_PASSWORD}|g" secrets/secrets-example.env
sed -i "s|username2replace|admin|g" security/patch-basic-auth.yml
sed -ir "s|(^.*)version: .*|\1version: ${VERSION}|" core_config/patch-version.yml
echo "  - core_config/patch-version.yml" >> kustomization.yml

if [[ ${OPEN_SOURCE} -eq 0 ]]; then
  sed -e "s|xxxxxxxx-.*|${MAGIC_NUMBER}$(uuidgen | cut -c 9-)|" armory/patch-diagnostics.yml
  echo "  - armory/patch-diagnostics.yml" >> kustomization.yml
fi

sudo chown -R 1000 ${BASE_DIR}

### Set up Kubernetes environment
echo "Installing K3s"
install_k3s
echo "Setting kubernetes context to Spinnaker namespace"
sudo env "PATH=$PATH" kubectl config set-context ${KUBERNETES_CONTEXT} --namespace ${NAMESPACE}
echo "Installing yq"
install_yq

### Deploy Spinnaker with Operator
cd ${BASE_DIR}/operator
./deploy.sh

echo 'source <(kubectl completion bash)' >>~/.bashrc

set +x
echo "It may take up to 10 minutes for this endpoint to work.  You can check by looking at running pods: 'kubectl -n ${NAMESPACE} get pods'"
echo "https://$(cat ${BASE_DIR}/.hal/public_endpoint)"
echo "username: 'admin'"
echo "password: '$(cat ${BASE_DIR}/.hal/.secret/spinnaker_password)'"