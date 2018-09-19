all: build

IMAGE := akutz/vk8s-conformance

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
DOCKER_RUN := docker run --rm $(DOCKER_ENV) -v $$(pwd)/data:/tf/data

# If YAKITY is set and a valid file path then copy it
# to data/yakity.sh so the container can access it via
# the mounted volume path.
YAKITY ?= ../yakity/yakity.sh
ifneq (,$(wildcard $(YAKITY)))
	DOCKER_RUN += -v $(abspath $(YAKITY)):/tf/data/yakity.sh:ro
endif

# Complete the docker run command by appending the image.
DOCKER_RUN += $(IMAGE)

build:
	docker build -t $(IMAGE) .

up:
	$(DOCKER_RUN) up $(NAME)

down:
	$(DOCKER_RUN) down $(NAME)

destroy:
	for i in 1 2 3; do \
	  govc vm.destroy "/SDDC-Datacenter/vm/Workloads/k8s-c0$${i}-$(NAME)" >/dev/null 2>&1; \
	  govc vm.destroy "/SDDC-Datacenter/vm/Workloads/k8s-w0$${i}-$(NAME)" >/dev/null 2>&1; \
	done

plan:
	$(DOCKER_RUN) plan $(NAME)

push:
	docker push $(IMAGE)

PHONY: build up down destroy plan push
