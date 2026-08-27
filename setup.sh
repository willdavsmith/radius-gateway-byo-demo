#!/usr/bin/env bash

set -euo pipefail

readonly REPO="${DEMO_REPO:-willdavsmith/radius-gateway-byo-demo}"
readonly ENVIRONMENT="${DEMO_ENVIRONMENT:-azure}"
readonly ACTION="${1:-help}"
readonly NAMESPACE="radius-demo-byo"
readonly GATEWAY_NAME="radius-demo-byo"
readonly GATEWAY_CLASS="radius-demo-byo-contour"
readonly HELM_RELEASE="radius-demo-byo-contour"
readonly OWNER_LABEL="radius-project.io/gateway-demo"
readonly GATEWAY_API_VERSION="v1.2.1"
readonly CONTOUR_CHART_VERSION="0.1.0"

require_tools() {
    local tool
    for tool in gh kubectl helm jq; do
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
    if kubectl get gateway radius -n radius-system >/dev/null 2>&1; then
        echo "error: Radius managed Gateway already exists; delete the prior routes application first" >&2
        exit 1
    fi
    if helm status contour -n radius-system >/dev/null 2>&1; then
        echo "error: Radius managed Contour release already exists; delete the prior routes application first" >&2
        exit 1
    fi
}

assert_owned_or_absent() {
    local resource="$1"
    local name="$2"
    shift 2
    local value
    if value="$(kubectl get "${resource}" "${name}" "$@" \
        -o "jsonpath={.metadata.labels.${OWNER_LABEL//./\\.}}" 2>/dev/null)"; then
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
    if kubectl get "${resource}" "${name}" "$@" >/dev/null 2>&1; then
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

    kubectl wait --for=condition=Accepted \
        "gatewayclass/${GATEWAY_CLASS}" --timeout=5m
    kubectl wait --for=condition=Programmed \
        "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=5m
}

verify_byo_infrastructure() {
    assert_managed_gateway_absent
    kubectl wait --for=condition=Accepted \
        "gatewayclass/${GATEWAY_CLASS}" --timeout=2m
    kubectl wait --for=condition=Programmed \
        "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=2m
    local service_type
    service_type="$(
        kubectl get service -n "${NAMESPACE}" \
            -l app.kubernetes.io/component=envoy \
            -o jsonpath='{.items[0].spec.type}'
    )"
    [[ "${service_type}" == "ClusterIP" ]] || {
        echo "error: expected BYO Envoy Service type ClusterIP, got ${service_type}" >&2
        exit 1
    }
    echo "verified: BYO Gateway is programmed and no Radius managed Gateway exists"
}

verify_byo_route() {
    local attempt
    local routes
    for ((attempt = 1; attempt <= 24; attempt++)); do
        routes="$(
            kubectl get httproute -A \
                -l radapp.io/application=gateway-byo-demo -o json
        )"
        if jq -e --arg gateway "${GATEWAY_NAME}" \
            --arg namespace "${NAMESPACE}" '
              .items | length == 1 and
              all(.[];
                any(.spec.parentRefs[]?;
                  .name == $gateway and .namespace == $namespace) and
                any(.status.parents[]?.conditions[]?;
                  .type == "Accepted" and .status == "True") and
                any(.status.parents[]?.conditions[]?;
                  .type == "ResolvedRefs" and .status == "True"))
            ' <<<"${routes}" >/dev/null; then
            echo "verified: Radius attached an accepted HTTPRoute to the BYO Gateway"
            return 0
        fi
        sleep 5
    done
    echo "error: Radius HTTPRoute was not accepted by the BYO Gateway" >&2
    return 1
}

assert_byo_application_absent() {
    if [[ -n "$(
        kubectl get httproute -A \
            -l radapp.io/application=gateway-byo-demo -o name
    )" ]]; then
        echo "error: gateway-byo-demo still has an HTTPRoute; delete the Radius application first" >&2
        exit 1
    fi
}

remove_byo_gateway() {
    local owner
    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
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
    if helm status "${HELM_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
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
        echo "ready: deploy .radius/app.bicep from the Copilot Radius canvas"
        ;;
    verify)
        require_tools
        require_target
        require_github_environment
        verify_environment_variables
        verify_byo_infrastructure
        verify_byo_route
        ;;
    teardown)
        require_tools
        require_target
        require_github_environment
        require_context_ack
        assert_byo_application_absent
        delete_environment_variable RADIUS_ROUTES_GATEWAY_NAME
        delete_environment_variable RADIUS_ROUTES_GATEWAY_NAMESPACE
        delete_environment_variable RADIUS_ROUTES_EXPOSURE
        remove_byo_gateway
        assert_managed_gateway_absent
        ;;
    *)
        echo "usage: DEMO_ACK_AKS_CONTEXT=context ./setup.sh {setup|verify|teardown}"
        ;;
esac
