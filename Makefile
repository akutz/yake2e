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
WORKERS ?= 1

DOCKER_ENV += --env TF_VAR_k8s_version="$(K8S_VERSION)"
DOCKER_ENV += --env TF_VAR_ctl_count="$(CONTROLLERS)"
DOCKER_ENV += --env TF_VAR_wrk_count="$(WORKERS)"
ifneq (,$(wildcard secure.env))
DOCKER_ENV += --env-file secure.env
endif
ifneq (,$(YAKITY))
ifneq (,$(wildcard $(YAKITY)))
data/yakity.sh: $(YAKITY)
	mkdir -p "$(@D)" && cp -f "$<" "$@"
up: data/yakity.sh
down: data/yakity.sh
plan: data/yakity.sh
endif
endif

DOCKER_RUN := docker run --rm $(DOCKER_ENV) -v $$(pwd)/data:/tf/data $(IMAGE)

build:
	docker build -t $(IMAGE) .

up:
	$(DOCKER_RUN) up $(NAME)

down:
	$(DOCKER_RUN) down $(NAME)

plan:
	$(DOCKER_RUN) plan $(NAME)

push:
	docker push $(IMAGE)

PHONY: build up down plan push
