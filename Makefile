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

# Transfer ownership of any existing k8s resources from a previous Helm release
.PHONY: helm-adopt
helm-adopt:
	@for kind in deployment service configmap serviceaccount; do \
	  if kubectl get $$kind $(SERVICE_NAME) -n $(NAMESPACE) >/dev/null 2>&1; then \
	    echo "Adopting $$kind/$(SERVICE_NAME) into release service-$(SERVICE_NAME)"; \
	    kubectl annotate $$kind $(SERVICE_NAME) -n $(NAMESPACE) \
	      meta.helm.sh/release-name=service-$(SERVICE_NAME) \
	      meta.helm.sh/release-namespace=$(NAMESPACE) --overwrite; \
	    kubectl label $$kind $(SERVICE_NAME) -n $(NAMESPACE) \
	      app.kubernetes.io/managed-by=Helm --overwrite; \
	  fi \
	done

.PHONY: deploy
deploy: k8s-namespace helm-adopt
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
