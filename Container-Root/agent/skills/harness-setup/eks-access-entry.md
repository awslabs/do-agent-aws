# Connect the agent to an EKS cluster

The agent runs inside the container. It can build its own kubeconfig there and test it, but it cannot
grant itself access to your cluster. That part is yours, on the host, with your own credentials. The
agent prints the lines below with your names filled in; you run them and tell it when done.

## What the agent does by itself (inside the container)
1. Finds your clusters: `aws eks list-clusters --region <region>` for each region it can see.
2. Writes a kubeconfig into its own home. The harness keeps the container's `/home/agent/.kube` under
   `wd/agent-state/.kube`, so it survives restarts:
   `aws eks update-kubeconfig --name <cluster> --region <region> --kubeconfig ~/.kube/config`
   When your host `~/.kube` is mounted there instead, that kubeconfig is yours: the agent gives you
   `aws eks update-kubeconfig --name <cluster> --region <region>` to run on the host, where it also makes the new
   context the current one, and never writes the file itself.
3. Verifies: `kubectl auth can-i list pods -A` must answer `yes`. Until your host step is done it answers
   `no` or `error: You must be logged in to the server (Unauthorized)`. That is expected, not a fault.

## What you run on the host (once per cluster)
The container calls AWS as the identity its credentials resolve to. Find that identity first, from the
host, with the same profile the container uses:

```sh
aws sts get-caller-identity --query Arn --output text
```

Then give that identity read-only access to the cluster. Pick the mechanism your cluster uses. In the
lines below, `<principal-arn>` is that ARN when it is an IAM user or role (`arn:aws:iam::...`). For an
assumed role (`arn:aws:sts::<account>:assumed-role/<role name>/<session>`) it is the role's own ARN, which
can carry a path the assumed-role ARN leaves out (IAM Identity Center roles have one), so ask IAM for it:

```sh
aws iam get-role --role-name <role name> --query Role.Arn --output text
```

The agent prints the lines with that ARN filled in, or with this question first when its own identity may
not ask IAM.

**Clusters with access entries (the default for new clusters):**

```sh
aws eks create-access-entry --cluster-name <cluster> --region <region> \
  --principal-arn <principal-arn> --type STANDARD
aws eks associate-access-policy --cluster-name <cluster> --region <region> \
  --principal-arn <principal-arn> --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy
```

`AmazonEKSViewPolicy` is read-only. Use `AmazonEKSEditPolicy` or `AmazonEKSClusterAdminPolicy` only if a
goal needs the agent to change objects; the cluster-status loop never does.

**Older clusters that still use the aws-auth ConfigMap:** add the identity as a mapped role or user with
a read-only group, for example with `eksctl`, and bind `view-only` to the built-in `view` ClusterRole:

```sh
eksctl create iamidentitymapping --cluster <cluster> --region <region> \
  --arn <principal-arn> --username agent --group view-only
kubectl create clusterrolebinding agent-view --clusterrole=view --group=view-only
```

Either way, nothing in these lines opens a port or changes the cluster's network. Access is through the
EKS API endpoint with your IAM identity.

## Verify (the agent does this; you can too)

```sh
kubectl auth can-i list pods -A
kubectl get pods -A
```

The first must print `yes`. The second lists the pods in every namespace. If the first cannot reach the cluster
at all (a timeout, no route to the host), the cluster endpoint is private and the container's network cannot reach
it; that is a VPC question for you, not an access-entry one. If the first says `yes` and the second fails, the
cluster's API answered, so read the error the second prints.

Nodes are cluster-scoped, and neither `AmazonEKSViewPolicy` nor the `view` ClusterRole covers them: the agent
reads them only when the cluster allows it, and says so otherwise.

## Keeping it
The kubeconfig lives at `~/.kube/config` inside the container, backed by `wd/agent-state/.kube`, so it
stays after `./stop.sh && ./run.sh`: a restart needs nothing moved. Only a `~/.kube` you create on the host later
changes that: `./run.sh` then mounts yours at `/home/agent/.kube`, which hides the kept file. Merge its contexts into yours
first, read through the running container (the kept file is root's); the doctor prints that line, and yours win where
both name the same context. The IAM credentials come from the host's `~/.aws` that the container mounts;
if those are temporary, the agent will ask you to refresh them when `aws sts get-caller-identity` fails.
