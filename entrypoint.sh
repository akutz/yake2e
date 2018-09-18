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

# If there's a yakity.sh in the data directory then use it.
if [ -f "data/yakity.sh" ]; then
  cat <<EOF >/tf/yakity.rb
require 'socket'
require 'uri'
server = TCPServer.new('127.0.0.1', 8000)
socket = server.accept; socket.gets
File.open("data/yakity.sh", "rb") do |file|
  socket.print "HTTP/1.1 200 OK\\r\\n" +
    "Content-Type: text/plain\\r\\n" +
    "Content-Length: #{file.size}\\r\\n" +
    "Connection: close\\r\\n" +
    "\\r\\n"
    IO.copy_stream(file, socket)
  socket.close
end
EOF
  ruby yakity.rb &
  export TF_VAR_yakity_url="http://127.0.0.1:8000"
fi

if [ "${CMD}" = "plan" ]; then
  exec terraform plan
elif [ "${CMD}" = "up" ]; then
  exec terraform apply -auto-approve
elif [ "${CMD}" = "down" ]; then
  exec terraform destroy -auto-approve && rm -f data/.last
fi
