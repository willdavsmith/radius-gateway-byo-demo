# Existing Gateway demo

This application declares `Radius.Compute/routes`, while `setup.sh` installs a
private Contour Gateway that remains user-owned. The verification proves Radius
PR [#12854](https://github.com/radius-project/radius/pull/12854) routes through
that Gateway without installing or adopting the managed
`radius-system/radius`, `GatewayClass/contour`, or `radius-system/contour`
resources.

## Prerequisites

Use the Radius Azure GitHub Environment that targets the same isolated AKS
cluster as the current `kubectl` context. `DEMO_ENVIRONMENT` must also be a
valid Kubernetes label value because recipe-output cleanup scopes both the
application and environment labels. Set `DEMO_REF` to the named remote branch
or tag containing these workflows.

```shell
export DEMO_REPO=willdavsmith/radius-gateway-byo-demo
export DEMO_ENVIRONMENT=azure
export DEMO_REF=willdavsmith-byo-gateway-verification
export DEMO_ACK_AKS_CONTEXT="$(kubectl config current-context)"
```

Do not start this scenario until the no-routes scenario has completed and the
shared AKS cluster is clean.

## Verification sequence

Run these commands in order:

```shell
./setup.sh setup
./setup.sh deploy
./setup.sh verify
./setup.sh delete
./setup.sh preservation-check
./setup.sh teardown
```

`setup` installs Gateway API v1.2.1, the demo Contour release, GatewayClass, and
Gateway. It sets `RADIUS_ROUTES_GATEWAY_NAME=radius-demo-byo` and
`RADIUS_ROUTES_GATEWAY_NAMESPACE=radius-demo-byo`, removes
`RADIUS_ROUTES_EXPOSURE`, and rejects any Radius lifecycle ownership markers.

`deploy` dispatches `run-rad-commands.yml` from `DEMO_REF`. `delete` dispatches
`delete-application.yml` from the same ref. Both commands capture the run URL
returned directly by `gh workflow run`, extract that exact run ID, and block on
`gh run watch --exit-status`.

`verify` proves the application HTTPRoute references the BYO Gateway, the
Gateway reports the attached route, an HTTP request succeeds through the BYO
Envoy service, and no managed Gateway lifecycle resources were installed or
adopted.

`preservation-check` is read-only. After the delete workflow, it proves the BYO
Gateway, GatewayClass, Contour Helm release, and all pre-existing Gateway API
CRDs remain without Radius lifecycle ownership metadata.

`teardown` repeats the preservation check before deleting anything. It then
applies the demo-only workaround for
[radius#12878](https://github.com/radius-project/radius/issues/12878), deleting
only namespaced recipe outputs with both exact labels
`radapp.io/application=gateway-byo-demo` and
`radapp.io/environment=$DEMO_ENVIRONMENT`. The allowlist covers HTTPRoute,
TCPRoute, TLSRoute, UDPRoute, Deployment, HorizontalPodAutoscaler, Service, and
Secret. Unavailable Gateway API kinds are skipped only after successful API
discovery; all other discovery and list errors fail teardown. Finally, teardown
removes the demo-owned BYO Gateway, GatewayClass, Contour release, namespace,
and GitHub Environment variables.

Gateway API CRDs remain because they are pre-existing, cluster-scoped resources
that may be shared.

All stable extension actions in the Azure deploy and delete workflows are
pinned to `radius-project/ai-extensions@0b12c9ed2531d3be4c2ffa18c4b1e6b237b1407c`.
Only `manage-routes-gateway` is pinned to the feature commit
`radius-project/radius@3aa81af42ae9a0f7d8413c6b3f6dc88c4a326726`.
