#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ] || shopt -oq posix 2>/dev/null; then
    echo "error: run this script as ./setup.sh or bash setup.sh, not sh setup.sh" >&2
    exit 2
fi

set -euo pipefail

readonly REPO="${DEMO_REPO:-willdavsmith/radius-gateway-byo-demo}"
readonly ENVIRONMENT="${DEMO_ENVIRONMENT:-azure}"
readonly WORKFLOW_REF="${DEMO_REF:-}"
readonly ACTION="${1:-help}"
readonly APPLICATION_NAME="gateway-byo-demo"
readonly APPLICATION_SELECTOR="radapp.io/application=${APPLICATION_NAME},radapp.io/environment=${ENVIRONMENT}"
readonly NAMESPACE="radius-demo-byo"
readonly GATEWAY_NAME="radius-demo-byo"
readonly GATEWAY_CLASS="radius-demo-byo-contour"
readonly HELM_RELEASE="radius-demo-byo-contour"
readonly OWNER_LABEL="radius-project.io/gateway-demo"
readonly LIFECYCLE_MANAGED_LABEL="app.kubernetes.io/managed-by"
readonly LIFECYCLE_MANAGED_BY="radius-repo"
readonly LIFECYCLE_ANNOTATION="radius-project.io/routes-gateway-lifecycle"
readonly GATEWAY_API_VERSION="v1.2.1"
readonly CONTOUR_CHART_VERSION="0.1.0"
readonly -a GATEWAY_API_CRDS=(
    "gatewayclasses.gateway.networking.k8s.io"
    "gateways.gateway.networking.k8s.io"
    "httproutes.gateway.networking.k8s.io"
    "backendtlspolicies.gateway.networking.k8s.io"
    "referencegrants.gateway.networking.k8s.io"
    "grpcroutes.gateway.networking.k8s.io"
    "tcproutes.gateway.networking.k8s.io"
    "tlsroutes.gateway.networking.k8s.io"
    "udproutes.gateway.networking.k8s.io"
)
readonly -a ORPHAN_ROUTE_RESOURCE_TYPES=(
    "httproutes.gateway.networking.k8s.io"
    "tcproutes.gateway.networking.k8s.io"
    "tlsroutes.gateway.networking.k8s.io"
    "udproutes.gateway.networking.k8s.io"
)
readonly -a ORPHAN_CORE_RESOURCE_TYPES=(
    "deployments.apps"
    "horizontalpodautoscalers.autoscaling"
    "services"
    "secrets"
)

PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

cleanup_route_probe() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
        wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
        PORT_FORWARD_PID=""
    fi
    if [[ -n "${PORT_FORWARD_LOG}" ]]; then
        rm -f "${PORT_FORWARD_LOG}"
        PORT_FORWARD_LOG=""
    fi
}
trap cleanup_route_probe EXIT

require_tools() {
    local tool
    if [[ "$#" -eq 0 ]]; then
        set -- gh kubectl helm jq curl
    fi
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || {
            echo "error: ${tool} is required" >&2
            exit 1
        }
    done
}

require_target() {
    [[ -n "${REPO}" ]] || {
        echo "error: set DEMO_REPO or pass owner/repo as argument 2" >&2
        exit 1
    }
    [[ -n "${ENVIRONMENT}" ]] || {
        echo "error: set DEMO_ENVIRONMENT or pass the GitHub Environment as argument 3" >&2
        exit 1
    }
    [[ "${#ENVIRONMENT}" -le 63 &&
        "${ENVIRONMENT}" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?$ ]] || {
        echo "error: DEMO_ENVIRONMENT must be a valid non-empty Kubernetes label value" >&2
        exit 1
    }
}

require_workflow_ref() {
    [[ -n "${WORKFLOW_REF}" ]] || {
        echo "error: set DEMO_REF to the remote branch or tag containing the workflows" >&2
        exit 1
    }
    [[ "${WORKFLOW_REF}" != *[[:space:]]* &&
        ! "${WORKFLOW_REF}" =~ ^[0-9a-fA-F]{40}$ ]] || {
        echo "error: DEMO_REF must be a named branch or tag, not whitespace or a commit SHA" >&2
        exit 1
    }
}

dispatch_and_watch_workflow() {
    local workflow="$1"
    shift
    local run_url
    local run_id
    run_url="$(
        gh workflow run "${workflow}" \
            --repo "${REPO}" \
            --ref "${WORKFLOW_REF}" \
            "$@"
    )" || {
        echo "error: failed to dispatch ${workflow} from ${WORKFLOW_REF}" >&2
        exit 1
    }
    [[ "${run_url}" =~ ^https?://[^[:space:]]+/actions/runs/([0-9]+)([/?][^[:space:]]*)?$ ]] || {
        echo "error: gh workflow run did not return an exact workflow run URL: ${run_url:-<empty>}" >&2
        exit 1
    }
    run_id="${BASH_REMATCH[1]}"
    echo "watching ${run_url}"
    gh run watch "${run_id}" --repo "${REPO}" --exit-status
}

require_github_environment() {
    if ! gh api "repos/${REPO}/environments/${ENVIRONMENT}" >/dev/null 2>&1; then
        echo "error: GitHub Environment '${ENVIRONMENT}' does not exist in ${REPO}" >&2
        echo "create and verify it in Radius → Environments → Create environment → Azure, then rerun setup" >&2
        exit 1
    fi
}

require_context_ack() {
    local context
    context="$(kubectl config current-context)"
    [[ -n "${context}" ]] || {
        echo "error: kubectl has no current context" >&2
        exit 1
    }
    [[ "${DEMO_ACK_AKS_CONTEXT:-}" == "${context}" ]] || {
        echo "error: refusing to mutate context '${context}'" >&2
        echo "set DEMO_ACK_AKS_CONTEXT='${context}' after confirming this is the isolated AKS demo cluster" >&2
        exit 1
    }
    echo "using acknowledged AKS context: ${context}"
}

resource_exists() {
    local resource="$1"
    local name="$2"
    shift 2
    local output
    output="$(
        kubectl get "${resource}" "${name}" "$@" --ignore-not-found -o name
    )" || {
        echo "error: failed to inspect ${resource}/${name}" >&2
        exit 1
    }
    [[ -z "${output}" || "${output}" != *$'\n'* ]] || {
        echo "error: discovery for ${resource}/${name} returned multiple resources" >&2
        exit 1
    }
    [[ -n "${output}" ]]
}

helm_release_exists() {
    local release="$1"
    local namespace="$2"
    local output
    output="$(
        helm list --all --namespace "${namespace}" \
            --filter "^${release}$" --short
    )" || {
        echo "error: failed to inspect Helm release ${namespace}/${release}" >&2
        exit 1
    }
    [[ -z "${output}" || "${output}" == "${release}" ]] || {
        echo "error: Helm discovery for ${namespace}/${release} returned unexpected output" >&2
        exit 1
    }
    [[ -n "${output}" ]]
}

environment_variable_exists() {
    local name="$1"
    local variables
    variables="$(
        gh variable list --repo "${REPO}" --env "${ENVIRONMENT}" \
            --json name --jq '.[].name'
    )" || {
        echo "error: failed to read variables from GitHub Environment '${ENVIRONMENT}'" >&2
        exit 1
    }
    grep -Fxq "${name}" <<<"${variables}"
}

delete_environment_variable() {
    local name="$1"
    if environment_variable_exists "${name}"; then
        gh variable delete "${name}" --repo "${REPO}" --env "${ENVIRONMENT}"
    fi
}

set_environment_variables() {
    gh variable set RADIUS_ROUTES_GATEWAY_NAME --body "${GATEWAY_NAME}" \
        --repo "${REPO}" --env "${ENVIRONMENT}"
    gh variable set RADIUS_ROUTES_GATEWAY_NAMESPACE --body "${NAMESPACE}" \
        --repo "${REPO}" --env "${ENVIRONMENT}"
    delete_environment_variable RADIUS_ROUTES_EXPOSURE
}

verify_environment_variables() {
    local gateway_name
    local gateway_namespace
    gateway_name="$(
        gh variable get RADIUS_ROUTES_GATEWAY_NAME \
            --repo "${REPO}" --env "${ENVIRONMENT}" --json value --jq '.value'
    )"
    gateway_namespace="$(
        gh variable get RADIUS_ROUTES_GATEWAY_NAMESPACE \
            --repo "${REPO}" --env "${ENVIRONMENT}" --json value --jq '.value'
    )"
    [[ "${gateway_name}" == "${GATEWAY_NAME}" &&
        "${gateway_namespace}" == "${NAMESPACE}" ]] || {
        echo "error: GitHub Environment does not select the demo BYO Gateway" >&2
        exit 1
    }
    if environment_variable_exists RADIUS_ROUTES_EXPOSURE; then
        echo "error: RADIUS_ROUTES_EXPOSURE must be unset in BYO mode" >&2
        exit 1
    fi
}

assert_managed_gateway_absent() {
    if resource_exists customresourcedefinition \
        gateways.gateway.networking.k8s.io &&
        resource_exists gateway radius -n radius-system; then
        echo "error: Radius managed Gateway radius-system/radius exists" >&2
        exit 1
    fi
    if resource_exists customresourcedefinition \
        gatewayclasses.gateway.networking.k8s.io &&
        resource_exists gatewayclass contour; then
        echo "error: Radius managed GatewayClass contour exists" >&2
        exit 1
    fi
    if helm_release_exists contour radius-system; then
        echo "error: Radius managed Contour release radius-system/contour exists" >&2
        exit 1
    fi
}

assert_owned_or_absent() {
    local resource="$1"
    local name="$2"
    shift 2
    local value
    if resource_exists "${resource}" "${name}" "$@"; then
        value="$(
            kubectl get "${resource}" "${name}" "$@" \
                -o "jsonpath={.metadata.labels.${OWNER_LABEL//./\\.}}"
        )"
        [[ "${value}" == "true" ]] || {
            echo "error: ${resource}/${name} already exists and is not owned by this demo" >&2
            exit 1
        }
    fi
}

assert_demo_owned_if_present() {
    local resource="$1"
    local name="$2"
    shift 2
    local value
    if resource_exists "${resource}" "${name}" "$@"; then
        value="$(
            kubectl get "${resource}" "${name}" "$@" \
                -o "jsonpath={.metadata.labels.${OWNER_LABEL//./\\.}}"
        )"
        [[ "${value}" == "true" ]] || {
            echo "error: refusing to delete ${resource}/${name}; it is not owned by this demo" >&2
            exit 1
        }
    fi
}

assert_demo_resource_preserved() {
    local resource="$1"
    local name="$2"
    shift 2
    local object
    object="$(kubectl get "${resource}" "${name}" "$@" -o json)" || {
        echo "error: expected demo resource ${resource}/${name} is missing" >&2
        exit 1
    }
    jq -e \
        --arg owner_label "${OWNER_LABEL}" \
        --arg managed_label "${LIFECYCLE_MANAGED_LABEL}" \
        --arg managed_by "${LIFECYCLE_MANAGED_BY}" \
        --arg annotation "${LIFECYCLE_ANNOTATION}" '
          .metadata.labels[$owner_label] == "true" and
          (.metadata.labels[$managed_label] // "") != $managed_by and
          .metadata.annotations[$annotation] == null
        ' <<<"${object}" >/dev/null || {
        echo "error: ${resource}/${name} lost demo ownership or gained Radius lifecycle ownership" >&2
        exit 1
    }
}

assert_gateway_crds_preserved() {
    local crd
    local object
    for crd in "${GATEWAY_API_CRDS[@]}"; do
        object="$(
            kubectl get customresourcedefinition "${crd}" -o json
        )" || {
            echo "error: pre-existing Gateway API CRD ${crd} was not preserved" >&2
            exit 1
        }
        jq -e \
            --arg managed_label "${LIFECYCLE_MANAGED_LABEL}" \
            --arg managed_by "${LIFECYCLE_MANAGED_BY}" \
            --arg annotation "${LIFECYCLE_ANNOTATION}" '
              (.metadata.labels[$managed_label] // "") != $managed_by and
              .metadata.annotations[$annotation] == null
            ' <<<"${object}" >/dev/null || {
            echo "error: Gateway API CRD ${crd} was adopted by the Radius lifecycle action" >&2
            exit 1
        }
    done
}

verify_byo_helm_release() {
    local status
    local values
    status="$(
        helm status "${HELM_RELEASE}" -n "${NAMESPACE}" -o json
    )" || {
        echo "error: expected BYO Helm release ${NAMESPACE}/${HELM_RELEASE} is missing" >&2
        exit 1
    }
    jq -e \
        --arg release "${HELM_RELEASE}" \
        --arg namespace "${NAMESPACE}" '
          .name == $release and
          .namespace == $namespace and
          .info.status == "deployed"
        ' <<<"${status}" >/dev/null || {
        echo "error: BYO Helm release ${NAMESPACE}/${HELM_RELEASE} is not deployed" >&2
        exit 1
    }

    values="$(
        helm get values "${HELM_RELEASE}" -n "${NAMESPACE}" -o json
    )" || {
        echo "error: failed to inspect BYO Helm release ownership" >&2
        exit 1
    }
    jq -e \
        --arg owner_label "${OWNER_LABEL}" \
        --arg managed_label "${LIFECYCLE_MANAGED_LABEL}" \
        --arg managed_by "${LIFECYCLE_MANAGED_BY}" \
        --arg annotation "${LIFECYCLE_ANNOTATION}" '
          .commonLabels[$owner_label] == "true" and
          (.commonLabels[$managed_label] // "") != $managed_by and
          .commonAnnotations[$annotation] == null
        ' <<<"${values}" >/dev/null || {
        echo "error: BYO Helm release lost demo ownership or was adopted by Radius" >&2
        exit 1
    }
}

install_byo_gateway() {
    assert_managed_gateway_absent
    assert_owned_or_absent namespace "${NAMESPACE}"
    assert_owned_or_absent gatewayclass "${GATEWAY_CLASS}"
    assert_owned_or_absent gateway "${GATEWAY_NAME}" -n "${NAMESPACE}"

    kubectl apply -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml |
        kubectl apply -f -
    kubectl label namespace "${NAMESPACE}" "${OWNER_LABEL}=true" --overwrite

    helm upgrade --install "${HELM_RELEASE}" contour \
        --repo https://projectcontour.github.io/helm-charts \
        --version "${CONTOUR_CHART_VERSION}" \
        --namespace "${NAMESPACE}" \
        --set gatewayAPI.manageCRDs=false \
        --set-string "configInline.gateway.gatewayRef.name=${GATEWAY_NAME}" \
        --set-string "configInline.gateway.gatewayRef.namespace=${NAMESPACE}" \
        --set-string envoy.service.type=ClusterIP \
        --set-string envoy.service.externalTrafficPolicy= \
        --set-string "commonLabels.${OWNER_LABEL//./\\.}=true" \
        --wait --timeout 5m

    cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAY_CLASS}
  labels:
    ${OWNER_LABEL}: "true"
spec:
  controllerName: projectcontour.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
  labels:
    ${OWNER_LABEL}: "true"
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: tls
      protocol: TLS
      port: 443
      tls:
        mode: Passthrough
      allowedRoutes:
        namespaces:
          from: All
EOF

    verify_byo_gateway_class
    kubectl wait --for=condition=Programmed \
        "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=5m
}

verify_byo_gateway_class() {
    local controller
    controller="$(
        kubectl get gatewayclass "${GATEWAY_CLASS}" \
            -o jsonpath='{.spec.controllerName}'
    )"
    [[ "${controller}" == "projectcontour.io/gateway-controller" ]] || {
        echo "error: GatewayClass ${GATEWAY_CLASS} uses unexpected controller ${controller}" >&2
        exit 1
    }
}

verify_byo_infrastructure() {
    assert_managed_gateway_absent
    verify_byo_gateway_class
    kubectl wait --for=condition=Programmed \
        "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=2m
    assert_demo_resource_preserved namespace "${NAMESPACE}"
    assert_demo_resource_preserved gatewayclass "${GATEWAY_CLASS}"
    assert_demo_resource_preserved gateway "${GATEWAY_NAME}" -n "${NAMESPACE}"
    assert_gateway_crds_preserved
    verify_byo_helm_release

    local services
    services="$(
        kubectl get service -n "${NAMESPACE}" \
            -l "app.kubernetes.io/instance=${HELM_RELEASE},app.kubernetes.io/component=envoy" \
            -o json
    )"
    jq -e '
      (.items | length) == 1 and
      .items[0].spec.type == "ClusterIP"
    ' <<<"${services}" >/dev/null || {
        echo "error: expected exactly one BYO Envoy ClusterIP Service" >&2
        exit 1
    }
    echo "verified: BYO infrastructure is ready, preserved, and not Radius-owned"
}

verify_http_through_byo_gateway() {
    local services
    local service
    local port=""
    local attempt
    local curl_status
    services="$(
        kubectl get service -n "${NAMESPACE}" \
            -l "app.kubernetes.io/instance=${HELM_RELEASE},app.kubernetes.io/component=envoy" \
            -o json
    )"
    service="$(
        jq -er '
          if (.items | length) == 1 then .items[0].metadata.name
          else error("expected exactly one BYO Envoy Service")
          end
        ' <<<"${services}"
    )" || {
        echo "error: could not resolve the BYO Envoy Service" >&2
        exit 1
    }

    PORT_FORWARD_LOG="$(mktemp)"
    kubectl port-forward -n "${NAMESPACE}" \
        "service/${service}" :80 >"${PORT_FORWARD_LOG}" 2>&1 &
    PORT_FORWARD_PID=$!

    for ((attempt = 1; attempt <= 40; attempt++)); do
        port="$(
            sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) -> 80.*/\1/p' \
                "${PORT_FORWARD_LOG}" | head -n 1
        )"
        [[ -n "${port}" ]] && break
        if ! kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
            cat "${PORT_FORWARD_LOG}" >&2
            echo "error: BYO Envoy port-forward exited before becoming ready" >&2
            exit 1
        fi
        sleep 0.25
    done
    [[ -n "${port}" ]] || {
        cat "${PORT_FORWARD_LOG}" >&2
        echo "error: timed out establishing the BYO Envoy port-forward" >&2
        exit 1
    }

    set +e
    curl -fsS --retry 12 --retry-delay 2 --retry-all-errors \
        --max-time 10 "http://127.0.0.1:${port}/" >/dev/null
    curl_status=$?
    set -e
    cleanup_route_probe
    [[ "${curl_status}" -eq 0 ]] || {
        echo "error: HTTP request through the BYO Gateway failed" >&2
        exit 1
    }
    echo "verified: application responds through the BYO Gateway"
}

verify_byo_route() {
    local attempt
    local gateway
    local routes
    for ((attempt = 1; attempt <= 24; attempt++)); do
        routes="$(
            kubectl get httproute -A \
                -l "${APPLICATION_SELECTOR}" -o json
        )"
        gateway="$(
            kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o json
        )"
        if jq -e --arg gateway "${GATEWAY_NAME}" \
            --arg namespace "${NAMESPACE}" '
              .items | length == 1 and
              all(.[];
                any(.spec.parentRefs[]?;
                  .name == $gateway and .namespace == $namespace))
            ' <<<"${routes}" >/dev/null &&
            jq -e '
              any(.status.listeners[]?;
                .name == "http" and .attachedRoutes >= 1)
            ' <<<"${gateway}" >/dev/null; then
            echo "verified: Radius attached an HTTPRoute to the BYO Gateway"
            verify_http_through_byo_gateway
            return
        fi
        sleep 5
    done
    echo "error: Radius HTTPRoute was not attached to the BYO Gateway" >&2
    return 1
}

delete_orphaned_app_recipe_outputs() {
    local resource
    local objects
    local count
    local route_apis
    echo "Removing radius#12878 orphaned outputs selected by ${APPLICATION_SELECTOR}."
    route_apis="$(
        kubectl api-resources \
            --api-group=gateway.networking.k8s.io \
            --namespaced=true \
            -o name
    )" || {
        echo "error: failed to discover namespaced Gateway API resources" >&2
        exit 1
    }
    for resource in \
        "${ORPHAN_ROUTE_RESOURCE_TYPES[@]}" \
        "${ORPHAN_CORE_RESOURCE_TYPES[@]}"; do
        if [[ "${resource}" == *".gateway.networking.k8s.io" ]] &&
            ! grep -Fxq "${resource}" <<<"${route_apis}"; then
            echo "Skipping unavailable Gateway API resource ${resource}."
            continue
        fi
        objects="$(
            kubectl get "${resource}" -A \
                -l "${APPLICATION_SELECTOR}" -o json
        )" || {
            echo "error: failed to inspect ${resource} for demo orphans" >&2
            exit 1
        }
        count="$(jq -er '.items | length' <<<"${objects}")"
        if [[ "${count}" -gt 0 ]]; then
            kubectl delete "${resource}" -A \
                -l "${APPLICATION_SELECTOR}" --ignore-not-found --wait=true
        fi
    done
}

assert_app_recipe_outputs_absent() {
    local resource
    local objects
    local route_apis
    route_apis="$(
        kubectl api-resources \
            --api-group=gateway.networking.k8s.io \
            --namespaced=true \
            -o name
    )" || {
        echo "error: failed to discover namespaced Gateway API resources" >&2
        exit 1
    }
    for resource in \
        "${ORPHAN_ROUTE_RESOURCE_TYPES[@]}" \
        "${ORPHAN_CORE_RESOURCE_TYPES[@]}"; do
        if [[ "${resource}" == *".gateway.networking.k8s.io" ]] &&
            ! grep -Fxq "${resource}" <<<"${route_apis}"; then
            echo "Skipping unavailable Gateway API resource ${resource}."
            continue
        fi
        objects="$(
            kubectl get "${resource}" -A \
                -l "${APPLICATION_SELECTOR}" -o json
        )" || {
            echo "error: failed to verify ${resource} cleanup" >&2
            exit 1
        }
        jq -e '.items | length == 0' <<<"${objects}" >/dev/null || {
            echo "error: ${resource} still has outputs for ${APPLICATION_NAME}" >&2
            exit 1
        }
    done
}

verify_byo_preservation() {
    verify_environment_variables
    verify_byo_infrastructure
    echo "verified: lifecycle cleanup preserved the BYO Gateway, GatewayClass, Contour release, and Gateway API CRDs"
}

remove_byo_gateway() {
    local owner
    if resource_exists namespace "${NAMESPACE}"; then
        owner="$(
            kubectl get namespace "${NAMESPACE}" \
                -o "jsonpath={.metadata.labels.${OWNER_LABEL//./\\.}}"
        )"
        if [[ "${owner}" != "true" ]]; then
            echo "error: refusing to remove namespace ${NAMESPACE}; it is not owned by this demo" >&2
            exit 1
        fi
    fi

    assert_demo_owned_if_present gateway "${GATEWAY_NAME}" -n "${NAMESPACE}"
    assert_demo_owned_if_present gatewayclass "${GATEWAY_CLASS}"
    kubectl delete gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" \
        --ignore-not-found --wait=true
    kubectl delete gatewayclass "${GATEWAY_CLASS}" \
        --ignore-not-found --wait=true
    if helm_release_exists "${HELM_RELEASE}" "${NAMESPACE}"; then
        helm uninstall "${HELM_RELEASE}" -n "${NAMESPACE}" --wait --timeout 5m
    fi
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true
    echo "Gateway API CRDs were intentionally retained because they are cluster-scoped and may be shared."
}

case "${ACTION}" in
    setup)
        require_tools
        require_target
        require_github_environment
        require_context_ack
        install_byo_gateway
        set_environment_variables
        verify_environment_variables
        verify_byo_infrastructure
        echo "ready: run ./setup.sh deploy for GitHub Environment ${ENVIRONMENT}"
        ;;
    deploy)
        require_tools gh
        require_target
        require_workflow_ref
        dispatch_and_watch_workflow run-rad-commands.yml \
            -f "environment=${ENVIRONMENT}"
        ;;
    verify)
        require_tools
        require_target
        require_github_environment
        verify_environment_variables
        verify_byo_infrastructure
        verify_byo_route
        ;;
    delete)
        require_tools gh
        require_target
        require_workflow_ref
        dispatch_and_watch_workflow delete-application.yml \
            -f "environment=${ENVIRONMENT}" \
            -f "application=${APPLICATION_NAME}"
        ;;
    preservation-check)
        require_tools
        require_target
        require_github_environment
        verify_byo_preservation
        ;;
    teardown)
        require_tools
        require_target
        require_github_environment
        require_context_ack
        verify_byo_preservation
        delete_orphaned_app_recipe_outputs
        assert_app_recipe_outputs_absent
        delete_environment_variable RADIUS_ROUTES_GATEWAY_NAME
        delete_environment_variable RADIUS_ROUTES_GATEWAY_NAMESPACE
        delete_environment_variable RADIUS_ROUTES_EXPOSURE
        remove_byo_gateway
        assert_managed_gateway_absent
        ;;
    *)
        echo "usage: DEMO_ACK_AKS_CONTEXT=context DEMO_REF=branch ./setup.sh {setup|deploy|verify|delete|preservation-check|teardown}"
        ;;
esac
