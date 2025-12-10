# 1. Observability Setup for OpenTelemetry Demo on AWS EKS
This directory contains the monitoring and alerting setup used for the OpenTelemetry Demo deployed on our EKS cluster.  


## 2. Installation Steps (Run After Cluster Deployment)

These steps must be executed **after the EKS cluster is created**, since observability tooling is NOT part of the CloudFormation template.


### Install kube-prometheus-stack

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

helm repo update

helm install observability prometheus-community/kube-prometheus-stack \

  -n observability --create-namespace



## 3. Accessing Observability Components

### ✔ Access Prometheus (Port 9090)

kubectl port-forward -n observability svc/observability-kube-prom-prometheus 9090:9090

### ✔ Access Grafana (Port 3000)

kubectl port-forward -n observability svc/observability-grafana 3000:80

### ✔ Access Alertmanager (Port 9093)

kubectl port-forward -n observability svc/observability-kube-prom-alertmanager 9093:9093


## 7. IAM, IRSA, and Required AWS Add-Ons for Observability

The observability stack requires several AWS IAM roles, Kubernetes service accounts (IRSA), and add-ons that **must be created manually** after cluster deployment.

These IAM components enable:

- ALB creation (Ingress → external access to Grafana/Prometheus)

- Node autoscaling for Prometheus scheduling

- EBS PersistentVolume provisioning for Prometheus

This section documents everything required so the observability layer can be rebuilt on a new cluster.




### AWS Load Balancer Controller (Required for Ingress, Grafana, Prometheus)

The ALB controller allows Kubernetes Ingress resources to automatically create AWS Application Load Balancers (ALBs).

#### Step 1 — Create IAM Policy

curl -o iam_policy_latest.json \

  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json


aws iam create-policy \

  --policy-name AWSLoadBalancerControllerIAMPolicy \

  --policy-document file://iam_policy_latest.json || true


#### Step 2 — Create IRSA Service Account

eksctl create iamserviceaccount \

  --cluster=$CLUSTER_NAME \

  --namespace=kube-system \

  --name=aws-load-balancer-controller \

  --role-name AmazonEKSLoadBalancerControllerRole \

  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \

  --override-existing-serviceaccounts \

  --approve \

  --region=$AWS_REGION


#### Step 3 — Install Load Balancer Controller

helm repo add eks https://aws.github.io/eks-charts

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \

  -n kube-system \

  --set clusterName=$CLUSTER_NAME \

  --set region=$AWS_REGION \

  --set serviceAccount.create=false \

  --set serviceAccount.name=aws-load-balancer-controller \

  --set vpcId=$VPC_ID

### Cluster Autoscaler (Prevents Prometheus from Staying Pending)


Prometheus is resource-heavy. Without autoscaling, it often fails to schedule due to lack of cluster capacity.

#### Step 1 — IAM Policy


cat <<EOF > cluster-autoscaler-policy.json

{

  "Version": "2012-10-17",

  "Statement": [

    {

      "Effect": "Allow",

      "Action": [

        "autoscaling:DescribeAutoScalingGroups",

        "autoscaling:DescribeAutoScalingInstances",

        "autoscaling:DescribeLaunchConfigurations",

        "autoscaling:DescribeTags",

        "autoscaling:SetDesiredCapacity",

        "autoscaling:TerminateInstanceInAutoScalingGroup",

        "ec2:DescribeLaunchTemplateVersions"

      ],

      "Resource": "*"

    }

  ]

}

EOF


aws iam create-policy \

  --policy-name AmazonEKSClusterAutoscalerPolicy \

  --policy-document file://cluster-autoscaler-policy.json || true

#### Step 2 — IRSA Service Account

eksctl create iamserviceaccount \

  --cluster=$CLUSTER_NAME \

  --namespace=kube-system \

  --name=cluster-autoscaler \

  --role-name AmazonEKSClusterAutoscalerRole \

  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AmazonEKSClusterAutoscalerPolicy \

  --override-existing-serviceaccounts \

  --approve \

  --region=$AWS_REGION



#### Step 3 — Install Cluster Autoscaler

helm repo add autoscaler https://kubernetes.github.io/autoscaler


helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \

  -n kube-system \

  --set autoDiscovery.clusterName=$CLUSTER_NAME \

  --set awsRegion=$AWS_REGION \

  --set rbac.serviceAccount.create=false \

  --set rbac.serviceAccount.name=cluster-autoscaler


### EBS CSI Driver (Required for Prometheus PersistentVolumes)

Prometheus uses PersistentVolumes backed by AWS EBS.

If the EBS CSI Driver is not installed, Prometheus PVCs will stay Pending forever.


#### Step 1 — IAM Policy

curl -o ebs-csi-policy.json \

  https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json

aws iam create-policy \

  --policy-name AmazonEKS_EBS_CSI_Driver_Policy \

  --policy-document file://ebs-csi-policy.json || true


#### Step 2 — IRSA Service Account

eksctl create iamserviceaccount \

  --cluster=$CLUSTER_NAME \

  --namespace=kube-system \

  --name=ebs-csi-controller-sa \

  --role-name AmazonEKS_EBS_CSI_DriverRole \

  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AmazonEKS_EBS_CSI_Driver_Policy \

  --override-existing-serviceaccounts \

  --approve \

  --region=$AWS_REGION

#### Step 3 — Install EBS CSI Add-On

aws eks create-addon \

  --cluster-name $CLUSTER_NAME \

  --addon-name aws-ebs-csi-driver \

  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole \

  --resolve-conflicts OVERWRITE \

  --region=$AWS_REGION

## 10. Troubleshooting Checklist

### ✔ Prometheus stuck at "Pending"

kubectl get pvc -n observability

If PVC = Pending → install EBS CSI Driver 


### ✔ ALB not created for Grafana / Prometheus

kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

Check for IAM permission errors or missing Load Balancer Controller (see Section 7.1)

### ✔ Cluster Autoscaler not scaling nodes

kubectl logs -n kube-system -l app=cluster-autoscaler

Check for autoscaling group configuration or IAM permission issues 

