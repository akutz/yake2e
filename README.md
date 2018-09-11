# vK8s Conformance
This project provides a turn-key solution for running the Kubernetes 
conformance tests on the VMware vSphere platform.

## Quick Start
To run the Kubernetes conformance tests follow these steps:

1. Build the Docker image:
```shell
$ docker build -t vk8s-conformance .
```

The image can alternatively be pulled with:
```shell
$ docker pull akutz/vk8s-conformance
```

Please note there is no CI set up to automatically upload new versions of
the image. So please build it locally for now to ensure it's the latest
version.

2. Create a file named `config.env` with the following values, replacing
the placeholders where appropriate:
```
TF_VAR_vsphere_server=VSPHERE_SERVER_FQDN
TF_VAR_vsphere_user=VSPHERE_ADMIN_USER_NAME
TF_VAR_vsphere_password=VSPHERE_ADMIN_USER_PASS
TF_VAR_vsphere_template=PATH_TO_CLOUD_INIT_ENABLED_VSPHERE_LINUX_TEMPLATE
TF_VAR_tls_ca_crt=BASE64_ENCODED_X509_CA_CRT_PEM
TF_VAR_tls_ca_key=BASE64_ENCODED_X509_CA_KEY_PEM
```

Please look in the file `input.tf` and add any other values to `config.env`
that need to override the defaults. For example, the variable `vsphere_network`
is defined with a default value of `VMC Networks/sddc-cgw-network-3`. To
override this in `config.env`, add:

```
TF_VAR_vsphere_network=MY_CUSTOM_NETWORK
```

3. Run the Docker image:
```shell
$ docker run --rm \
             --env-file config.env \
             -v $(pwd)/data:/tf/data \
             vk8s-conformance \
             up
```

Congrats! The conformance tests will be running on the worker node. Use
`sudo journalctl -xefu kube-conformance` or 
`sudo tail -f /var/log/kube-conformance/e2e.log` to follow the progress
of the tests.
