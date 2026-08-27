# Existing Gateway demo

This public demo application declares `Radius.Compute/routes`, but its setup script installs a compatible private Contour Gateway and configures the GitHub Environment to select it. Radius validates the existing infrastructure without creating or adopting `radius-system/radius`.

## Run

The repository expects a Radius Azure GitHub Environment named `azure` that targets the same AKS cluster as the current `kubectl` context. Confirm that the context is an isolated demo cluster before acknowledging it:

```shell
export DEMO_ACK_AKS_CONTEXT="$(kubectl config current-context)"
./setup.sh setup
```

Until `radius-project/radius#12854` merges, do not use the Radius canvas Deploy button: the current canvas regenerates the provider workflow from `main` and removes the feature-under-test. Trigger the already-pinned workflow directly:

```shell
gh workflow run run-rad-commands.yml \
  --repo willdavsmith/radius-gateway-byo-demo \
  -f environment=azure
```

Follow the run in GitHub Actions or with `gh run watch`.

```shell
./setup.sh verify
kubectl get gateway radius-demo-byo -n radius-demo-byo
kubectl get gateway radius -n radius-system
```

Expected result: `radius-demo-byo/radius-demo-byo` is programmed, the application HTTPRoute is accepted, and `radius-system/radius` does not exist.

Trigger the pinned delete workflow directly. Radius retains the BYO stack. After the workflow finishes, remove only this demo's resources and variables with:

```shell
gh workflow run delete-application.yml \
  --repo willdavsmith/radius-gateway-byo-demo \
  -f environment=azure \
  -f application=gateway-byo-demo

./setup.sh teardown
```

Gateway API CRDs remain because cluster-scoped CRDs may be shared.

Until `radius-project/radius#12854` merges, the workflows pin Radius actions to commit `000e3749e3b072b75eb6a46ae171688e417bfb5c`.
