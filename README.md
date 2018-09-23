# vK8s Conformance
This project provides a turn-key solution for running the Kubernetes 
conformance tests on the VMware vSphere platform.

## Quick Start
To run the Kubernetes conformance tests follow these steps:

1. Build the Docker image:
```shell
$ make build
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
TF_VAR_run_conformance_tests=true
TF_VAR_vsphere_template=PATH_TO_CLOUD_INIT_ENABLED_VSPHERE_LINUX_TEMPLATE
```

Please look in the file `input.tf` and add any other values to `config.env`
that need to override the defaults. For example, the variable `vsphere_network`
is defined with a default value of `VMC Networks/sddc-cgw-network-3`. To
override this in `config.env`, add:

```
TF_VAR_vsphere_network=MY_CUSTOM_NETWORK
```

3. Create a file named `secure.env` with the following values, replacing
the placeholders where appropriate:
```
TF_VAR_tls_ca_crt=BASE64_ENCODED_X509_CA_CRT_PEM
TF_VAR_tls_ca_key=BASE64_ENCODED_X509_CA_KEY_PEM

TF_VAR_vsphere_server=VSPHERE_SERVER_FQDN
TF_VAR_vsphere_user=VSPHERE_ADMIN_USER_NAME
TF_VAR_vsphere_password=VSPHERE_ADMIN_USER_PASS
```

4. Turn up a cluster:
```shell
$ NAME=k8s make up
```

Congrats! The conformance tests will be running on the worker node.
Use `sudo journalctl -xefu kube-conformance` or
`sudo tail -f /var/log/kube-conformance/e2e.log` to follow the progress
of the tests.

## Run the e2e tests against a remote cluster
Running the e2e conformance tests against a remote cluster is also
easy to do with vk8s-conformance.

The first three steps are the same as above: build the image and
create the files `config.env` and `secure.env`.

4. Enable external access to the cluster by appending AWS
credentials to the file `secure.env`, replacing the placeholders
where appropriate:

```
AWS_LOAD_BALANCER=true
AWS_ACCESS_KEY_ID=AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION=AWS_DEFAULT_REGION
```

5. Run the tests:
```shell
$ NAME=k8s make test
```

## Run the e2e tests with an external cloud-provider
It's possible to use an external cloud provider with either
of the two test options: asynchronous and against a remote
cluster. Doing so simply requires using the environment variable
`EXTERNAL=true` when running `make up` or `make test`. This
indicates that an external cloud-provider should be used.
Supported, external cloud providers include:
* [cloud-provider-vsphere](https://github.com/kubernetes/cloud-provider-vsphere)