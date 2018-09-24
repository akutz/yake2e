#!/bin/sh

# posix complaint
# verified by https://www.shellcheck.net

set -o pipefail

GINKGO_FOCUS="${GINKGO_FOCUS:-\\[Conformance\\]}"
GINKGO_SKIP="${GINKGO_SKIP:-Alpha|Kubectl|\\[(Disruptive|Feature:[^\\]]+|Flaky)\\]}"

case "${1}" in
  run)
    /var/lib/kubernetes/e2e/platforms/linux/amd64/e2e.test \
      -ginkgo.focus "${GINKGO_FOCUS}" \
      -ginkgo.skip "${GINKGO_SKIP}" \
      -disable-log-dump \
      -provider "skeleton" \
      -report-dir "/var/log/kubernetes/e2e" \
      2>&1 | tee /var/log/kubernetes/e2e/e2e.log
    exit_code="${?}"
    touch /var/log/kubernetes/e2e/.done
    exit "${exit_code}"
    ;;
  tgz)
    while [ ! -f /var/log/kubernetes/e2e/.done ]; do sleep 1; done

    (cd /var/log/kubernetes/e2e && \
      tar czf /tmp/e2e.tgz \
      --exclude .done -- * >/tmp/tar.log 2>&1)

    if exit_code="${?}" && [ "${exit_code}" -ne "0" ]; then
      cat /tmp/tar.log; exit "${?}"
    fi

    base64 </tmp/e2e.tgz | tr -d '\n'
    ;;
  *)
    exec /bin/sh
    ;;
esac
