# Pinned Gateway API schemas

`gateway.networking.k8s.io/httproute_v1.json` derives from the Standard Gateway API
v1.6.2 CRD bundle vendored by infra commit `a0c0119`, using
`infra/scripts/update-gateway-schemas.py`. The generator closes declared object
properties unless arbitrary fields are allowed, and pins apiVersion/kind enums.
The source is Apache 2.0 licensed; LICENSE is included here. Validation uses
these pinned files before the existing external custom-resource catalog.
