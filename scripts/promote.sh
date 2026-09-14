#!/usr/bin/bash
# Move the :prod tag. This is the change-management gate.
#
# With Satellite out of scope, a tag move stands in for a content view
# promotion. Say so on camera - "in your estate this is a content view
# promotion; same gate, same approval, different tool" - because the
# infrastructure audience will be wondering.
set -euo pipefail

NS="${NS:?Set NS, e.g. NS=quay.io/tichomir}"
VER="${VER:?Set VER, e.g. VER=1.1}"
IMAGE="${IMAGE:-im-train}"

echo "== promoting ${IMAGE}:${VER} to :prod =="
skopeo copy "docker://${NS}/${IMAGE}:${VER}" "docker://${NS}/${IMAGE}:prod"

echo
echo "== :prod now resolves to =="
skopeo inspect "docker://${NS}/${IMAGE}:prod" \
    | jq -r '{digest: .Digest, created: .Created, labels: .Labels}'

cat <<NEXT

On the host:
  bootc upgrade          # stages the new digest
  bootc status           # shows staged, pending reboot
  systemctl reboot

Compare the digest above with what the host reports after reboot. They must
match; that is the verification step worth showing.
NEXT
