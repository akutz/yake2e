#!/bin/sh

set -o pipefail

usage() {
  cat <<EOF 1>&2
usage: ${0} CMD NAME [ARGS...]

ARGS

  CMD
    The command to execute.

  NAME
    The name of the cluster to deploy. Should be safe
    to use as a host and file name. Must be unique
    in the content of the vCenter to which the cluster
    is being deployed as well as in the context of the
    data directory.

COMMANDS

  up NAME
    Turns up a new cluster

  down NAME
    Turns down an existing cluster

  plan NAME
    A dry-run version of up

  info NAME [OUTPUTS...]
    Prints information about an existing cluster.
    If no arguments are provided then all of the
    information is printed.

  test NAME [GINKGO_FOCUS]
    Runs the e2e conformance suite against an
    existing cluster. When provided, a single
    argument can specify the Ginkgo focus string.
  CMD  The command to execute. Valid commands are:
       up   - Turns up a new cluster
       down - Turns down the cluster
       plan - A dry-run for up
       info - Prints the state of an existing cluster
       test - Runs the e2e conformance tests against
              an existing cluster
  
  NAME The name of the cluster against which to
       execute CMD.
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

# Drop out of the script if there aren't at least two args.
[ "${#}" -lt 2 ] && { usage; fatal "invalid number of arguments" 1; }

CMD="${1}"; shift
NAME="${1}"; shift

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

E2E_SH="data/${NAME}/e2e.sh"
if [ ! -f "${E2E_SH}" ]; then
  cat <<EOF >"${E2E_SH}"
#!/bin/sh

GINKGO_FOCUS="\${1:-\\[Conformance\\]}"
GINKGO_SKIP="\${2:-Alpha|Kubectl|\\[(Disruptive|Feature:[^\\]]+|Flaky)\\]}"

E2E_DIR="data/${NAME}/e2e"
E2E_BIN_DIR="\${E2E_DIR}/platforms/linux/amd64"
E2E_BIN="\${E2E_BIN_DIR}/e2e.test"
E2E_LOG_DIR="\${E2E_DIR}/log"
KUBECTL_BIN="\${E2E_BIN_DIR}/kubectl"

EXTERNAL_FQDN="\$(terraform output external_fqdn)"
E2E_URL="http://\${EXTERNAL_FQDN}/kubernetes-test.tar.gz"
KUBECTL_URL="http://\${EXTERNAL_FQDN}/kubectl"
CURL="curl --retry 5 --retry-delay 1 --retry-max-time 120"

export PATH="\${E2E_BIN_DIR}:\${PATH}"
export KUBECONFIG="/tf/data/${NAME}/kubeconfig"

mkdir -p "\${E2E_DIR}" "\${E2E_LOG_DIR}"

# Download the e2e package if it doesn't exist.
if [ ! -f "\${E2E_BIN}" ]; then
  \${CURL} -L "\${E2E_URL}" | \\
  tar -xzvC "\${E2E_DIR}" \\
    --exclude='kubernetes/platforms/darwin' \\
    --exclude='kubernetes/platforms/windows' \\
    --exclude='kubernetes/platforms/linux/arm' \\
    --exclude='kubernetes/platforms/linux/arm64' \\
    --exclude='kubernetes/platforms/linux/ppc64le' \\
    --exclude='kubernetes/platforms/linux/s390x' \\
    --strip-components=1
    exit_code="\${?}"
    [ "\${exit_code}" -gt "1" ] && exit "\${exit_code}"
fi

# Download kubectl if it doesn't exist.
if [ ! -f "\${KUBECTL_BIN}" ]; then
  \${CURL} -Lo "\${KUBECTL_BIN}" "\${KUBECTL_URL}" || exit "\${?}"
  chmod 0755 "\${KUBECTL_BIN}"
fi

\${E2E_BIN} \\
  -ginkgo.focus "\${GINKGO_FOCUS}" \\
  -ginkgo.skip "\${GINKGO_SKIP}" \\
  -- \\
  --disable-log-dump \\
  --report-dir="\${E2E_LOG_DIR}" | 
  tee "\${E2E_LOG_DIR}/e2e.log"
EOF
  chmod 0755 "${E2E_SH}"
fi

case "${CMD}" in
  plan) exec terraform plan ;;
  info) exec terraform output "${@}" ;;
  up)   exec terraform apply -auto-approve ;;
  down) exec terraform destroy -auto-approve ;;
  test) exec "${E2E_SH}" "${@}";;
  sh)   exec /bin/sh ;;
esac

echo "So long and thanks for all the fish."
