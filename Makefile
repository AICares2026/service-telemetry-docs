# Load .env.local if present
-include .env.local
export

ECR_REGISTRY ?= 952893849914.dkr.ecr.us-east-1.amazonaws.com
ECR_REPO     ?= aicares-application
AWS_REGION   ?= us-east-1
CLUSTER_NAME ?= aiops-agent-demo-cluster
NAMESPACE    ?= aicares
SERVICE_NAME  = telemetry-docs
IMAGE_TAG    ?= $(shell git rev-parse HEAD)
ECR_BASE      = $(ECR_REGISTRY)/$(ECR_REPO)
HELM_CHART    = ./helm/service-chart
HELM_VALUES   = ./helm/values.yaml

.PHONY: ecr-login
ecr-login:
	aws ecr get-login-password --region $(AWS_REGION) | \
	  docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: build
build:
	docker build -t $(ECR_BASE)/$(SERVICE_NAME):$(IMAGE_TAG) .

.PHONY: push
push: ecr-login build
	docker push $(ECR_BASE)/$(SERVICE_NAME):$(IMAGE_TAG)

.PHONY: k8s-auth
k8s-auth:
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)

.PHONY: k8s-namespace
k8s-namespace: k8s-auth
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

# Delete resources owned by a previous Helm release so our release can create them fresh.
# Required when spec.selector is immutable and the old chart used different labels.
.PHONY: helm-purge-old
helm-purge-old:
	@echo "Removing old resources for $(SERVICE_NAME) if owned by another release..."
	@for kind in deployment service configmap serviceaccount; do \
	  owner=$$(kubectl get $$kind $(SERVICE_NAME) -n $(NAMESPACE) \
	    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null); \
	  if [ -n "$$owner" ] && [ "$$owner" != "service-$(SERVICE_NAME)" ]; then \
	    echo "  Deleting $$kind/$(SERVICE_NAME) (owned by '$$owner')"; \
	    kubectl delete $$kind $(SERVICE_NAME) -n $(NAMESPACE) --ignore-not-found; \
	  fi \
	done

.PHONY: deploy
deploy: k8s-namespace helm-purge-old
	helm upgrade --install service-$(SERVICE_NAME) $(HELM_CHART) \
	  --namespace $(NAMESPACE) \
	  --values $(HELM_VALUES) \
	  --set image.tag=$(IMAGE_TAG) \
	  --wait --timeout 5m

.PHONY: push-deploy
push-deploy: push deploy

.PHONY: undeploy
undeploy:
	helm uninstall service-$(SERVICE_NAME) --namespace $(NAMESPACE) --ignore-not-found

.PHONY: status
status: k8s-auth
	kubectl get pods,svc -n $(NAMESPACE) -l app=$(SERVICE_NAME)
