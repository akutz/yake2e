#!/bin/sh

CMD="${1:-plan}"
NAME="${2}"

[ -z "${NAME}" ] && [ -f "data/.last" ] && NAME=$(cat data/.last)

if [ -n "${NAME}" ]; then
  mkdir -p data
  echo "${NAME}" >data/.last
  export TF_VAR_ctl_vm_name="k8s-c%02d-${NAME}"
  export TF_VAR_wrk_vm_name="k8s-w%02d-${NAME}"
  export TF_VAR_ctl_network_hostname="${TF_VAR_ctl_vm_name}"
  export TF_VAR_wrk_network_hostname="${TF_VAR_wrk_vm_name}"
  sed -i 's~data/terraform.state~data/'"${NAME}"'/terraform.state~g' data.tf
  terraform init
fi

if [ "${CMD}" = "plan" ]; then
  exec terraform plan
elif [ "${CMD}" = "up" ]; then
  exec terraform apply -auto-approve
elif [ "${CMD}" = "down" ]; then
  exec terraform destroy -auto-approve && rm -f data/.last
fi
