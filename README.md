# Existing Gateway demo

This public demo application declares `Radius.Compute/routes`, but its setup script installs a compatible private Contour Gateway and configures the GitHub Environment to select it. Radius validates the existing infrastructure without creating or adopting `radius-system/radius`.

## Run

The repository expects a Radius Azure GitHub Environment named `azure` that targets the same AKS cluster as the current `kubectl` context. Confirm that the context is an isolated demo cluster before acknowledging it:

```shell
export DEMO_ACK_AKS_CONTEXT="$(kubectl config current-context)"
./setup.sh setup
```

Open the repository in the GitHub Copilot app and deploy the root `.radius/app.bicep` with environment `azure`.

```shell
./setup.sh verify
kubectl get gateway radius-demo-byo -n radius-demo-byo
kubectl get gateway radius -n radius-system
```

Expected result: `radius-demo-byo/radius-demo-byo` is programmed, the application HTTPRoute is accepted, and `radius-system/radius` does not exist.

Delete `gateway-byo-demo` in the Radius canvas. Radius retains the BYO stack. Remove only this demo's resources and variables with:

```shell
./setup.sh teardown
```

Gateway API CRDs remain because cluster-scoped CRDs may be shared.

Until `radius-project/radius#12854` merges, the workflows pin Radius actions to commit `000e3749e3b072b75eb6a46ae171688e417bfb5c`.
