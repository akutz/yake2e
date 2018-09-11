all: build

IMAGE=akutz/vk8s-conformance

build:
	docker build -t $(IMAGE) .

up:
	docker run --rm --env-file secure.env -v $$(pwd)/data:/tf/data $(IMAGE) up $(NAME)

down:
	docker run --rm --env-file secure.env -v $$(pwd)/data:/tf/data $(IMAGE) down $(NAME)

plan:
	docker run --rm --env-file secure.env -v $$(pwd)/data:/tf/data $(IMAGE) plan $(NAME)

push:
	docker push $(IMAGE)

PHONY: build up down plan push
