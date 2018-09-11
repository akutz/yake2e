FROM alpine:3.8
LABEL "maintainer" "Andrew Kutz <akutz@vmware.com>"

# Install the common dependencies.
RUN apk --no-cache add \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    less \
    libc6-compat \
    openssh-client \
    tar \
    unzip \
    util-linux

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
