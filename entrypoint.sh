#!/bin/sh

# posix complaint
# verified by https://www.shellcheck.net

set -o pipefail

usage() {
  cat <<EOF 1>&2
usage: ${0} NAME CMD [ARGS...]

ARGS

  NAME
    The name of the cluster to deploy. Should be safe
    to use as a host and file name. Must be unique
    in the content of the vCenter to which the cluster
    is being deployed as well as in the context of the
    data directory.

  CMD
    The command to execute.

COMMANDS

  up
    Turns up a new cluster

  down
    Turns down an existing cluster

  plan
    A dry-run version of up

  info [OUTPUTS...]
    Prints information about an existing cluster.
    If no arguments are provided then all of the
    information is printed.

  test
    Schedules a job on turned up cluster where the
    job runs the e2e conformance tests.

  logs
    Follows the test log.
EOF
}

# Returns a success if the provided argument is a whole number.
is_whole_num() { echo "${1}" | grep -q '^[[:digit:]]\{1,\}$'; }

# echo2 echos the provided arguments to file descriptor 2, stderr.
echo2() {
  echo "${@}" 1>&2
}

# fatal MSG [EXIT_CODE]
#  Prints the supplied message to stderr and returns the shell's
#  last known exit code, $?. If a second argument is provided the
#  function returns its value as the return code.
fatal() {
  exit_code="${?}"; is_whole_num "${2}" && exit_code="${2}"
  [ "${exit_code}" -eq "0" ] && exit 0
  echo2 "FATAL [${exit_code}] - ${1}"; exit "${exit_code}"
}

# Define how curl should be used.
CURL="curl --retry 5 --retry-delay 1 --retry-max-time 120"

################################################################################
##                                   main                                     ##
################################################################################
# Drop out of the script if there aren't at least two args.
[ "${#}" -lt 2 ] && { usage; fatal "invalid number of arguments" 1; }

NAME="${1}"; shift
CMD="${1}"; shift

# Configure the data directory.
mkdir -p data
sed -i 's~data/terraform.state~data/'"${NAME}"'/terraform.state~g' data.tf
export TF_VAR_name="${NAME}"
export TF_VAR_ctl_vm_name="k8s-c%02d-${NAME}"
export TF_VAR_wrk_vm_name="k8s-w%02d-${NAME}"
export TF_VAR_ctl_network_hostname="${TF_VAR_ctl_vm_name}"
export TF_VAR_wrk_network_hostname="${TF_VAR_wrk_vm_name}"

# Check to see if the load-balancer was requested.
if [ "${AWS_LOAD_BALANCER}" = "true" ]; then

  # If any of the AWS access keys are missing then exit the script.
  [ -z "${AWS_ACCESS_KEY_ID}" ] && \
    fatal "load balancer config missing AWS_ACCESS_KEY_ID"
  [ -z "${AWS_SECRET_ACCESS_KEY}" ] && \
    fatal "load balancer config missing AWS_SECRET_ACCESS_KEY"
  [ -z "${AWS_DEFAULT_REGION}" ] && \
    fatal "load balancer config missing AWS_DEFAULT_REGION"

  # Copy the providers into the project.
  cp -f vmc/providers_aws.tf vmc/providers_local.tf vmc/providers_tls.tf .

  # Copy the load-balancer configuration into the project.
  cp -f vmc/load_balancer.tf load_balancer.tf

  # Copy the external K8s kubeconfig generator into the project.
  cp -f vmc/k8s_admin.tf .

  echo "external cluster access enabled"
fi

# Check to see if a CA needs to be generated.
#
# The warning (SC2154) for TF_VAR_tls_ca_crt and TF_VAR_tls_ca_key not being 
# assigned is disabled since the environment variables are defined externally.
#
# shellcheck disable=SC2154
if [ -z "${TF_VAR_tls_ca_crt}" ] || [ -z "${TF_VAR_tls_ca_key}" ]; then

  # If either the CA certificate or key is missing then a new pair must
  # be generated.
  unset TF_VAR_tls_ca_crt TF_VAR_tls_ca_key

  # Copy the providers into the project.
  cp -f vmc/providers_tls.tf .

  # Copy the CA generator into the project.
  cp -f vmc/tls_ca.tf .

  echo "one-time TLS CA generation enabled"
fi

# If no yakity URL is defined, there's a gist authentication file at 
# /root/.gist, and there's a yakity source at /tmp/yakity.sh, then upload 
# the yakity script to a gist so the local yakity script is consumeable 
# by Terraform's http provider.
if [ -z "${TF_VAR_yakity_url}" ] && \
   [ -f /root/.gist ] && [ -f /tmp/yakity.sh ]; then

  # Check to see if an existing yakity gist can be updated.
  if [ -f "data/.yakity.gist" ]; then

    echo "updating an existing yakity gist"

    # Read the gist URL from the file or exit with an error.
    if ! gurl="$(cat data/.yakity.gist)"; then
      fatal "failed to read data/.yakity.gist"
    fi

    # If the file was empty then exist with an error.
    [ -n "${gurl}" ] || fatal "data/.yakity.gist is empty" 1

    # If a gist ID can be parsed from the URL then use it to update
    # an existing gist instead of creating a new one.
    if ! gist_id="$(echo "${gurl}" | grep -o '[^/]\{32\}')"; then
      fatal "failed to parse gist ID from gist url ${gurl}"
    fi

    gist -u "${gist_id}" /tmp/yakity.sh 1>/dev/null || 
      fatal "failed to update existing yakity gist ${gurl}"

  # There's no existing yakity gist, so one should be created.
  else
    echo "create a new yakity gist"

    # Create a new gist with data/yakity.sh
    gurl=$(gist -pR /tmp/yakity.sh | tee data/.yakity.gist) || \
      fatal "failed to uplooad yakity gist"
  fi

  # Provide the yakity gist URL to Terraform.
  rgurl="$(echo "${gurl}" | \
    sed 's~gist.github.com~gist.githubusercontent.com~')" || \
    fatal "failed to transform gist URL ${gurl}"

  export TF_VAR_yakity_url="${rgurl}/yakity.sh"
  echo "using yakity gist ${TF_VAR_yakity_url}"
fi

# Check to see if there is a previous etcd discovery URL value. If so, 
# overwrite etcd.tf with that information.
if disco=$(terraform output etcd 2>/dev/null) && [ -n "${disco}" ]; then
  printf 'locals {\n  etcd_discovery = "%s"\n}\n' "${disco}" >etcd.tf
fi

# Make sure terraform has everything it needs.
terraform init

setup_kube() {
  KUBE_DIR="data/${NAME}/.kubernetes/linux_amd64"; mkdir -p "${KUBE_DIR}"
  export PATH="${KUBE_DIR}:${PATH}"

  if [ -f "${KUBE_DIR}/artifactz.txt" ]; then
    K8S_ARTIFACT_PREFIX=$(cat "${KUBE_DIR}/artifactz.txt")
  else
    EXTERNAL_FQDN=$(terraform output external_fqdn)
    K8S_ARTIFACT_PREFIX=$(${CURL} "http://${EXTERNAL_FQDN}/artifactz")
    printf '%s' "${K8S_ARTIFACT_PREFIX}" >"${KUBE_DIR}/artifactz.txt"
  fi

  KUBE_CLIENT_URL="${K8S_ARTIFACT_PREFIX}/kubernetes-client-linux-amd64.tar.gz"
  if [ ! -f "${KUBE_DIR}/kubectl" ]; then
    ${CURL} -L "${KUBE_CLIENT_URL}" | tar xzC "${KUBE_DIR}" --strip-components=3
  fi

  KUBECTL="kubectl --kubeconfig "data/${NAME}/kubeconfig""
}

test_logs() {
  setup_kube || exit
  while [ -z "${POD_NAME}" ]; do
    POD_NAME=$(${KUBECTL} get pods --selector=job-name=e2e | \
               grep Running | awk '{print $1}')
    [ -n "${POD_NAME}" ] || sleep 1
  done
  ${KUBECTL} logs -f "${POD_NAME}" e2e
}

test_start() {
  setup_kube || exit
  KUBE_TEST_URL="${K8S_ARTIFACT_PREFIX}/kubernetes-test.tar.gz"

  cat <<EOF >"data/${NAME}/test-job-spec.yaml"
apiVersion: batch/v1
kind: Job
metadata:
  name: e2e
spec:
  template:
    spec:
      volumes:
      - name: kubernetes
        emptyDir: {}
      containers:
      - name: setup
        image: centos:7.5.1804
        volumeMounts:
        - name: kubernetes
          mountPath: /var/lib/kubernetes
        args:
          - /bin/sh
          - -c
          - >
            echo "\${KUBECONFIG_GZ}" | base64 -d | gzip -d >/var/lib/kubernetes/kubeconfig;
            ${CURL} ${KUBE_CLIENT_URL} | tar xvzC /var/lib;
            ${CURL} ${KUBE_TEST_URL} | tar xvzC /var/lib;
            touch /var/lib/kubernetes/.ready
        env:
          - name: KUBECONFIG_GZ
            value: "$(gzip -9c <"data/${NAME}/kubeconfig" | base64 | tr -d '\n')"
      - name: e2e
        image: centos:7.5.1804
        volumeMounts:
        - name: kubernetes
          mountPath: /var/lib/kubernetes
        args:
          - /bin/sh
          - -c
          - >
            while [ ! -f /var/lib/kubernetes/.ready ]; do sleep 1; done;
            /var/lib/kubernetes/platforms/linux/amd64/e2e.test \
              -ginkgo.focus '\\[Conformance\\]' \
              -ginkgo.skip 'Alpha|Kubectl|\\[(Disruptive|Feature:[^\\]]+|Flaky)\\]' \
              -- \
              --disable-log-dump \
              2>&1;
        env:
          - name:  KUBECONFIG
            value: /var/lib/kubernetes/kubeconfig
          - name:  PATH
            value: /var/lib/kubernetes/client/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      restartPolicy: Never
  backoffLimit: 4
EOF

  ${KUBECTL} create -f "data/${NAME}/test-job-spec.yaml"
  ${KUBECTL} get pods --selector=job-name=e2e | grep ContainerCreating
}

case "${CMD}" in
  plan) 
    terraform plan
    ;;
  info)
    terraform output "${@}"
    ;;
  up)
    terraform apply -auto-approve
    ;;
  down)
    terraform destroy -auto-approve
    ;;
  test)
    test_start
    ;;
  logs)
    test_logs
    ;;
  sh)
    exec /bin/sh
    ;;
esac

exit_code="${?}"
echo "So long and thanks for all the fish."
exit "${@}"
