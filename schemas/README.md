# Pinned custom-resource schemas

These schemas derive from the Standard Gateway API v1.6.2 bundle and the
AWS Load Balancer Controller chart 3.6.2 CRDs vendored by infra commit `a0c0119`,
using `infra/scripts/update-gateway-schemas.py`. The generator closes declared
object properties unless arbitrary fields are allowed, and pins apiVersion/kind
enums. Sources are Apache 2.0 licensed; LICENSE is included here. Validation uses
these pinned files before the existing external custom-resource catalog.
