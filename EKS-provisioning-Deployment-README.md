# EKS Frontend with AWS Application Load Balancer

A command-first runbook for exposing a frontend running on Amazon EKS through an AWS Application Load Balancer (ALB).

## Architecture

```text
Internet
   |
   v
AWS Application Load Balancer
   |
   v
Kubernetes Ingress
   |
   v
frontend-service (ClusterIP :80)
   |
   +-------------------+
   |                   |
   v                   v
Frontend Pod       Frontend Pod
   :80                 :80
```

The AWS Load Balancer Controller connects the Kubernetes Ingress to the AWS ALB.

## 1. Environment

```text
AWS Region:     us-east-1
EKS Cluster:    second-cluster
VPC:            vpc-08fbc44f8bfdd1f0c
Namespace:      default
Controller NS:  kube-system
```

## 2. Connect to EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name second-cluster
kubectl config current-context
kubectl get nodes
```

Nodes should be `Ready`.

## 3. Deploy Frontend

```bash
kubectl apply -f frontend-deployment.yaml
kubectl get pods
kubectl get pods -o wide
```

Expected frontend Pods:

```text
frontend-xxxxx   1/1   Running
frontend-yyyyy   1/1   Running
```

For `ImagePullBackOff` or `ErrImagePull`:

```bash
kubectl describe pod <POD_NAME>
```

Check the `Events` section.

## 4. Create Frontend Service

```bash
kubectl apply -f frontend-service.yaml
kubectl get svc frontend-service
kubectl get endpoints frontend-service
```

The Service should be `ClusterIP` on port `80`, with both frontend Pod IPs as endpoints.

## 5. Get EKS VPC ID

```bash
aws eks describe-cluster \
  --name second-cluster \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text
```

Used in this setup:

```text
vpc-08fbc44f8bfdd1f0c
```

## 6. Create IAM Policy

Download the AWS Load Balancer Controller policy:

```bash
curl -o iam_policy.json \
https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

Create it:

```bash
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

If you get `EntityAlreadyExists`, the policy already exists. Verify it instead:

```bash
aws iam get-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

## 7. Create IAM Role

Create the trust policy:

```bash
cat > trust-policy.json <<'EOF2'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF2
```

Create the role:

```bash
aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://trust-policy.json
```

Attach the policy:

```bash
aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

Verify:

```bash
aws iam list-attached-role-policies \
  --role-name AmazonEKSLoadBalancerControllerRole
```

## 8. Create ServiceAccount

```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl get serviceaccount aws-load-balancer-controller -n kube-system
```

## 9. Configure EKS Pod Identity

Verify the Pod Identity Agent:

```bash
kubectl get pods -n kube-system | grep eks-pod-identity-agent
```

Create the association:

```bash
aws eks create-pod-identity-association \
  --cluster-name second-cluster \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKSLoadBalancerControllerRole \
  --region us-east-1
```

Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name second-cluster \
  --region us-east-1
```

Flow:

```text
Controller Pod
      |
      v
ServiceAccount
      |
      v
EKS Pod Identity
      |
      v
IAM Role
      |
      v
IAM Policy
      |
      v
AWS ELB APIs
```

## 10. Install Helm

```bash
curl -fsSL -o get_helm.sh \
https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

chmod 700 get_helm.sh

./get_helm.sh

helm version
```

## 11. Add AWS EKS Helm Repository

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm search repo eks/aws-load-balancer-controller
```

If Helm says the `eks` repository already exists with the same configuration, that is fine.

## 12. Install AWS Load Balancer Controller

Use the existing ServiceAccount and explicitly provide the VPC ID:

```bash
helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=second-cluster \
  --set region=us-east-1 \
  --set vpcId=vpc-08fbc44f8bfdd1f0c \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

`serviceAccount.create=false` is used because the ServiceAccount was already created.

The explicit VPC ID avoids the VPC discovery problem encountered through EC2 instance metadata.

## 13. Verify Controller

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

Expected:

```text
READY   UP-TO-DATE   AVAILABLE
2/2     2            2
```

Check logs:

```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

Both controller Pods should be `1/1 Running` before continuing.

## 14. Create ALB Ingress

`frontend-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
  name: frontend-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip

spec:
  ingressClassName: alb

  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

Apply:

```bash
kubectl apply -f frontend-ingress.yaml
```

### What the settings mean

```text
ingressClassName: alb
```
AWS Load Balancer Controller manages the Ingress.

```text
scheme: internet-facing
```
Creates a public ALB.

```text
target-type: ip
```
The ALB targets frontend Pod IPs directly.

```text
path: /
```
Routes `/` to `frontend-service:80`.

## 15. Watch ALB Provisioning

```bash
kubectl get ingress frontend-ingress -w
```

After successful reconciliation, `ADDRESS` becomes the ALB DNS name, for example:

```text
k8s-default-frontend-xxxxxxxx.us-east-1.elb.amazonaws.com
```

Stop with `Ctrl+C`.

## 16. Verify Ingress

```bash
kubectl get ingress frontend-ingress
kubectl describe ingress frontend-ingress
```

Check that the backend is:

```text
frontend-service:80
```

and that an ALB DNS name appears under `ADDRESS`.

## 17. Verify AWS ALB

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,State:State.Code,Type:Type}' \
  --output table
```

Expected:

```text
State: active
Type: application
```

## 18. Verify Target Group

```bash
aws elbv2 describe-target-groups \
  --region us-east-1 \
  --query 'TargetGroups[].{Name:TargetGroupName,TargetType:TargetType,Port:Port,ARN:TargetGroupArn}' \
  --output table
```

For this setup:

```text
TargetType: ip
Port:       80
```

Check target health:

```bash
aws elbv2 describe-target-health \
  --region us-east-1 \
  --target-group-arn <TARGET_GROUP_ARN>
```

Targets should become `healthy`.

## 19. End-to-End Test

Get the ALB DNS:

```bash
kubectl get ingress frontend-ingress
```

Test:

```bash
curl http://<ALB-DNS-NAME>
```

Expected: frontend HTML.

Then open the same URL in a browser:

```text
http://<ALB-DNS-NAME>
```

## 20. DNS Troubleshooting

If curl returns:

```text
Could not resolve host
```

check:

```bash
nslookup <ALB-DNS-NAME>
```

Test Google's DNS:

```bash
nslookup <ALB-DNS-NAME> 8.8.8.8
```

For a diagnostic HTTP test:

```bash
curl --resolve \
<ALB-DNS-NAME>:80:<ALB-IP> \
http://<ALB-DNS-NAME>
```

If this returns the frontend HTML, the ALB, target group and application path are working and the remaining issue is local DNS resolution.

## 21. Debugging Workflow

```text
Frontend Pods
      |
      v
frontend-service
      |
      v
frontend-ingress
      |
      v
AWS Load Balancer Controller
      |
      v
AWS Application Load Balancer
      |
      v
Target Group
      |
      v
Target Health
      |
      v
DNS
      |
      v
curl / Browser
```

Useful commands:

```bash
kubectl get pods -o wide
kubectl get svc frontend-service
kubectl get endpoints frontend-service
kubectl get ingress frontend-ingress
kubectl describe ingress frontend-ingress
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer-controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

## 23. Verification Checklist

```text
[ ] EKS kubeconfig configured
[ ] Nodes Ready
[ ] Frontend Pods Running
[ ] frontend-service created
[ ] Service endpoints populated

[ ] IAM policy exists
[ ] IAM role exists
[ ] Policy attached to role
[ ] Pod Identity Agent Running
[ ] Pod Identity association exists
[ ] Controller ServiceAccount exists

[ ] Helm installed
[ ] EKS Helm repository added
[ ] AWS Load Balancer Controller chart available
[ ] Controller 2/2 available

[ ] frontend-ingress created
[ ] ingressClassName = alb
[ ] scheme = internet-facing
[ ] target-type = ip
[ ] path = /

[ ] ALB DNS appears in ADDRESS
[ ] AWS ALB state = active
[ ] AWS ALB type = application
[ ] Target Group exists
[ ] Target type = ip
[ ] Targets healthy

[ ] ALB DNS resolves
[ ] curl returns frontend HTML
[ ] Browser opens frontend
```

## Final Request Flow

```text
Browser
   |
   v
AWS Application Load Balancer :80
   |
   v
Kubernetes Ingress
   |
   v
frontend-service :80
   |
   +-------------------+
   |                   |
   v                   v
Frontend Pod       Frontend Pod
   :80                 :80
```

## Backend Deployment 
```
kubectl apply -f frontend-ingress.yaml

kubectl apply -f backend-deployment.yaml

kubectl apply -f backend-service.yaml

kubectl get pods -l app=backend -o wide

kubectl logs \
  $(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')

kubectl get svc backend-service

kubectl exec -it \
$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}') \
-- wget -qO- http://backend-service:3000/api/message

output : {"message":"Hello from the ECS backend task!"}

```
## Database Deployment Pending

```
# ============================================================
# 0. Verify EBS CSI Driver Add-on
# ============================================================

aws eks list-addons \
  --cluster-name second-cluster \
  --region us-east-1

# If aws-ebs-csi-driver is NOT listed, create it:
aws eks create-addon \
  --cluster-name second-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1

# Verify add-on status
aws eks describe-addon \
  --cluster-name second-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1 \
  --query "addon.status" \
  --output text

kubectl get pods -n kube-system | grep ebs-csi

# ============================================================
# 1. Secret
# ============================================================

kubectl apply -f secret.yaml
kubectl get secret database-secret


# ============================================================
# 2. Persistent Storage
# ============================================================

kubectl apply -f database-pvc.yaml
kubectl get pvc database-pvc

# If PVC is Pending
kubectl get storageclass


# ============================================================
# 3. PostgreSQL Deployment
# ============================================================

kubectl apply -f database-deployment.yaml
kubectl get pods -l app=database

# If Pod is not Running
kubectl describe pod -l app=database


# ============================================================
# 4. PostgreSQL Service
# ============================================================

kubectl apply -f database-service.yaml
kubectl get svc database-service
kubectl get endpoints database-service


# ============================================================
# 5. Connect to PostgreSQL
# ============================================================

kubectl exec -it \
$(kubectl get pods -l app=database -o jsonpath='{.items[0].metadata.name}') \
-- psql -U hireflow -d hireflow

# Inside PostgreSQL
SELECT current_database();
SELECT version();

```