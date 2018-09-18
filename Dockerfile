FROM golang:1.11.0-alpine3.8 as build
LABEL "maintainer" "Andrew Kutz <akutz@vmware.com>"

RUN apk --no-cache add git

ENV GOVMOMI_VERSION=0.18.0
RUN go get -d github.com/vmware/govmomi/govc
RUN git -C "${GOPATH}/src/github.com/vmware/govmomi" checkout -b v${GOVMOMI_VERSION} v${GOVMOMI_VERSION}
RUN go install github.com/vmware/govmomi/govc

FROM alpine:3.8
LABEL "maintainer" "Andrew Kutz <akutz@vmware.com>"

# Copy govc from the build stage.
COPY --from=build /go/bin/govc /usr/local/bin/govc

# Install the common dependencies.
RUN apk --no-cache add ca-certificates curl unzip

# Download Terraform and place its binary in /usr/bin.
ENV TF_VERSION=0.11.8
ENV TF_ZIP=terraform_${TF_VERSION}_linux_amd64.zip
ENV TF_URL=https://releases.hashicorp.com/terraform/${TF_VERSION}/${TF_ZIP}
RUN curl -sSLO "${TF_URL}" && unzip "${TF_ZIP}" -d /usr/bin
RUN rm -f "${TF_ZIP}"

# Create the /tf directory. This is the working directory from which
# the terraform command is executed.
RUN mkdir /tf
WORKDIR /tf

# Copy the assets into the working directory.
COPY *.tf /tf/
COPY cloud_config.yaml /tf/

RUN terraform init

COPY entrypoint.sh /tf/
RUN chmod 0755 /tf/entrypoint.sh

CMD [ "plan" ]
ENTRYPOINT [ "/tf/entrypoint.sh" ]
