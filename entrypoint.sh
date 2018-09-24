#!/bin/sh

# posix complaint
# verified by https://www.shellcheck.net

set -o pipefail

usage() {
  cat <<EOF 1>&2
usage: yake2e NAME CMD [ARGS...]

ARGS

  NAME
    The name of the cluster to deploy. Should be safe to use as a host and file 
    name. Must be unique in the content of the vCenter to which the cluster is 
    being deployed as well as in the context of the data directory.

    If TF_VAR_cloud_provider=external then "-ccm" is
    appended to whatever name is provided.

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
    Prints information about an existing cluster. If no arguments are provided 
    then all of the information is printed.

  test
    Schedules the e2e conformance tests as a job.

  tdel
    Delete the e2e conformance tests job.

  tlog
    Follows the test log.

  tget
    Blocks until the tests have completed and then downloads the test artifacts.
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

# If TF_VAR_cloud_provider=external then NAME=${NAME}-ccm to reflect
# the use of an external cloud provider.
old_name="${NAME}"

# The warning (SC2154) for TF_VARTF_VAR_cloud_provider not being assigned
# is disabled since the environment variable is defined externally.
#
# shellcheck disable=SC2154
if [ "${TF_VAR_cloud_provider}" = "external" ]; then
  NAME_PREFIX="ccm"
fi
NAME_PREFIX="${NAME_PREFIX:-k8s}"
NAME="${NAME_PREFIX}-${NAME}"
echo "${old_name} is now ${NAME}"

# Configure the data directory.
mkdir -p data
sed -i 's~data/terraform.state~data/'"${NAME}"'/terraform.state~g' data.tf
export TF_VAR_name="${NAME}"
export TF_VAR_ctl_vm_name="c%02d"
export TF_VAR_wrk_vm_name="w%02d"
export TF_VAR_ctl_network_hostname="${TF_VAR_ctl_vm_name}"
export TF_VAR_wrk_network_hostname="${TF_VAR_wrk_vm_name}"

# If any of the AWS access keys are missing then exit the script.
if [ -n "${AWS_ACCESS_KEY_ID}" ] && \
  [ -n "${AWS_SECRET_ACCESS_KEY}" ] && \
  [ -n "${AWS_DEFAULT_REGION}" ]; then

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
    gurl="$(cat data/.yakity.gist)" || fatal "failed to read data/.yakity.gist"

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

# Make sure terraform has everything it needs.
terraform init

# Check to see if there is a previous etcd discovery URL value. If so, 
# overwrite etcd.tf with that information.
if disco=$(terraform output etcd 2>/dev/null) && [ -n "${disco}" ]; then
  printf 'locals {\n  etcd_discovery = "%s"\n}\n' "${disco}" >etcd.tf
fi

setup_kube() {
  kube_dir="data/${NAME}/.kubernetes/linux_amd64"; mkdir -p "${kube_dir}"
  export PATH="${kube_dir}:${PATH}"

  # Get the external FQDN of the cluster from the Terraform output cache.
  ext_fqdn=$(terraform output external_fqdn) || \
    fatal "failed to read external fqdn"

  # If there is a cached version of the artifact prefix then read it.
  if [ -f "data/${NAME}/artifactz" ]; then

    echo "reading existing artifactz.txt"

    # Get the kubertnetes artifact prefix from the file.
    kube_prefix=$(cat "data/${NAME}/artifactz") || \
      fatal "failed to read data/${NAME}/artifactz"

  # The artifact prefix has not been cached, so cache it.
  else
    # Get the artifact prefix from the cluster.
    kube_prefix=$(${CURL} "http://${ext_fqdn}/artifactz" | \
      tee "data/${NAME}/artifactz") || \
      fatal "failed to get k8s artifactz prefix"
  fi

  # If the kubectl program has not been cached then it needs to be downloaded.
  if [ ! -f "${kube_dir}/kubectl" ]; then
    ${CURL} -L "${kube_prefix}/kubernetes-client-linux-amd64.tar.gz" | \
      tar xzC "${kube_dir}" --strip-components=3
    exit_code="${?}" && \
      [ "${exit_code}" -gt "1" ] && \
      fatal "failed to download kubectl" "${exit_code}"
  fi

  # Define an alias for the kubectl program that includes the path to the
  # kubeconfig file and targets the e2e namespace for all operations.
  #
  # The --kubeconfig flag is used instead of exporting KUBECONFIG because
  # this results in command lines that can be executed from the host as
  # well since all paths are relative.
  KUBECTL="kubectl --kubeconfig "data/${NAME}/kubeconfig" -n e2e"
}

setup_test_pod_name() {
  setup_kube || exit

  # Keep trying to get the name of the e2e pod.
  echo "getting the name of the e2e pod"
  i=0; while true; do
    [ "${i}" -ge "5" ] && fatal "failed to get e2e pod" 1
    pod_name=$(${KUBECTL} get pods | grep 'Running\|Completed' | awk '{print $1}')
    [ -n "${pod_name}" ] && return 0
    sleep 1; i=$((i+1))
  done
}

test_logs() {
  setup_test_pod_name || exit

  # Tail the logs of the e2e job's pod.
  ${KUBECTL} logs -f "${pod_name}" run || fatal "failed to tail e2e log"
}

test_tgz() {
  setup_test_pod_name || exit

  # Save the results to the data directory.
  ${KUBECTL} logs -f "${pod_name}" tgz | \
    base64 -d >"data/${NAME}/e2e-logs.tar.gz" || \
    fatal "failed to tail e2e log"

  echo "saved test artifacts to data/${NAME}/e2e-logs.tar.gz"
}

test_delete() {
  setup_kube || exit

  # Delete the test job.
  ${KUBECTL} delete jobs e2e || fatal "failed to delete e2e job"
}

test_start() {
  setup_kube || exit

  # If the e2e job spec is not cached then download it from the cluster.
  [ -f "data/${NAME}/e2e-job.yaml" ] || \
    ${CURL} "http://${ext_fqdn}/e2e/job.yaml" >"data/${NAME}/e2e-job.yaml" || \
    fatal "failed to download e2e job spec"

  # Create the e2e job.
  ${KUBECTL} create -f "data/${NAME}/e2e-job.yaml" || \
    fatal "failed to create e2e job"

  # Get the name of the pod created for the e2e job.
  ${KUBECTL} get pods | grep -v Terminating || \
    fatal "failed to get e2e pod"
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
  tdel)
    test_delete
    ;;
  tlog)
    test_logs
    ;;
  tget)
    test_tgz
    ;;
  sh)
    exec /bin/sh
    ;;
esac

exit_code="${?}"
echo "So long and thanks for all the fish."
exit "${@}"
