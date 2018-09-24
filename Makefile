all: build

E2E_IMAGE := gcr.io/kubernetes-conformance-testing/yake2e:latest
E2E_JOB_IMAGE := gcr.io/kubernetes-conformance-testing/yake2e-job:latest

# Versions of the software packages installed on the controller and
# worker nodes. Please note that not all the software packages listed
# below are installed on both controllers and workers. Some is intalled
# on one, and some the other. Some software, such as jq, is installed
# on both controllers and workers.
#
# K8S_VERSION may be set to:
#
#    * release/(latest|stable|<version>)
#    * ci/(latest|<version>)
#
# To see a full list of supported versions use the Google Storage
# utility, gsutil, and execute "gsutil ls gs://kubernetes-release/release"
# for GA releases or "gsutil ls gs://kubernetes-release-dev" for dev
# releases.
K8S_VERSION ?= release/stable

# The number of conroller and worker nodes.
CONTROLLERS ?= 2
WORKERS ?= 2

# The cloud provider to use.
CLOUD_PROVIDER ?= vsphere

DOCKER_ENV += --env TF_VAR_k8s_version="$(K8S_VERSION)"
DOCKER_ENV += --env TF_VAR_ctl_count="$(CONTROLLERS)"
DOCKER_ENV += --env TF_VAR_wrk_count="$(WORKERS)"
DOCKER_ENV += --env TF_VAR_cloud_provider="$(CLOUD_PROVIDER)"
ifneq (,$(wildcard secure.env))
DOCKER_ENV += --env-file secure.env
endif
ifneq (,$(wildcard config.env))
DOCKER_ENV += --env-file config.env
endif

# Build the command used to run the Docker image.
DOCKER_RUN := docker run -t --rm $(DOCKER_ENV) -v $$(pwd)/data:/tf/data

# Map the terraform plug-ins directory into the Docker image so any
# plug-ins Terraform needs are persisted beyond the lifetime of the
# container and saves time when launching new containers.
DOCKER_RUN += -v $$(pwd)/data/.terraform/plugins:/tf/.terraform/plugins

# If GIST and YAKITY are both set to valid file paths then
# mount GIST to /root/.gist and YAKITY to /tmp/yakity.sh
# so the local yakity source may be uploaded to a gist and made 
# available to Terraform's http provider.
GIST ?= $(HOME)/.gist
YAKITY ?= ../yakity/yakity.sh
ifneq (,$(wildcard $(GIST)))
ifneq (,$(wildcard $(YAKITY)))
DOCKER_RUN += -v $(abspath $(GIST)):/root/.gist:ro
DOCKER_RUN += -v $(abspath $(YAKITY)):/tmp/yakity.sh:ro
endif
endif

# Complete the docker run command by appending the image.
DOCKER_RUN_SH := $(DOCKER_RUN) -i $(E2E_IMAGE)
DOCKER_RUN += $(E2E_IMAGE)

.Dockerfile.built: 	Dockerfile \
					*.tf vmc/*.tf \
					cloud_config.yaml \
					entrypoint.sh
	docker build -t $(E2E_IMAGE) . && touch "$@"

.Dockerfile.job.built: 	Dockerfile.job \
						e2e-job.sh
	docker build -t $(E2E_JOB_IMAGE) -f "$<" . && touch "$@"

build: .Dockerfile.built .Dockerfile.job.built

.Dockerfile.pushed: .Dockerfile.built
	docker push $(E2E_IMAGE) && touch "$@"

.Dockerfile.job.pushed: .Dockerfile.job.built
	docker push $(E2E_JOB_IMAGE) && touch "$@"

push: .Dockerfile.pushed .Dockerfile.job.pushed

up: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@

down: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@

plan: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@

info: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@ $(OUTPUT)

test: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@ $(GINKGO_FOCUS)

logs: .Dockerfile.built
	$(DOCKER_RUN) $(NAME) $@

sh: .Dockerfile.built
	$(DOCKER_RUN_SH) $(NAME) $@

PHONY: up down plan info test logs sh
