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

# Delete any existing deployment/service with the same name so Helm can create
# them fresh (required when spec.selector is immutable and labels differ).
.PHONY: k8s-clean
k8s-clean:
	kubectl delete deployment service-$(SERVICE_NAME) -n $(NAMESPACE) --ignore-not-found
	kubectl delete service    service-$(SERVICE_NAME) -n $(NAMESPACE) --ignore-not-found

.PHONY: deploy
deploy: k8s-namespace k8s-clean
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
	kubectl get pods,svc -n $(NAMESPACE) -l app=service-$(SERVICE_NAME)
