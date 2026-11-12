# EKS + GitHub Actions demo — OIDC version

A tiny Flask app, built by GitHub Actions, pushed to Amazon ECR, and run on EKS.

This is the twin of the `eks-manual` lab: same app, same cluster, same "everything runs on a
GitHub runner, started by hand" setup. The difference is **how GitHub Actions gets into AWS**:

- `eks-manual`: an IAM **user** with a long-lived **access key**, pasted into GitHub secrets.
- `eks-oidc` (this one): **no key at all.** AWS trusts GitHub as an **OIDC identity provider**.
  For each run, GitHub signs a short token that says *"this is repo X, branch Y, workflow Z"*.
  AWS checks it against an IAM **role**'s trust policy and hands out credentials that expire in
  1 hour. The "user" is the GitHub repository itself.

And since Docker Hub needs a token (and its private repos aren't free), the image goes to
**Amazon ECR**, which the same OIDC role can push to. So **GitHub stores no secrets at all**:
the Secrets tab stays empty.

| Action | Who does it | Credential | Where it is kept |
|---|---|---|---|
| Prove "I am a run of this repo" | GitHub Actions runner (a fresh VM on GitHub's servers) | OIDC token (JWT), signed by GitHub, lives ~5 minutes | nowhere — requested during the run |
| Talk to AWS | the runner, as IAM **role** `github-ci` (you create it by hand) | temporary AWS credentials, 1 hour | nowhere — `sts:AssumeRoleWithWebIdentity` during the run |
| Push image to ECR | the runner, as role `github-ci` | an ECR login made from those credentials | nowhere |
| Deploy into Kubernetes | the runner, as role `github-ci`, mapped by an EKS access entry | the same temporary credentials | the cluster (Terraform grants it) |
| Pull image from ECR | the EKS **nodes** | the nodes' own IAM role | the node group (Terraform creates it) |
| Create/destroy the cluster | You | your own AWS credentials | your laptop (`aws configure`) |

```
repo/
├── app/                  Flask app + Dockerfile
├── k8s/app.yaml          Deployment + LoadBalancer Service
├── iam/                  policies to paste in the console (trust policy for reference, ECR push)
├── terraform/            EKS cluster (copied from the k8s course) + the CI role's cluster permissions
└── .github/workflows/
    ├── whoami.yml        the OIDC handshake alone: show the token's claims, assume the role
    ├── build-push.yml    build image, push to ECR
    ├── deploy.yml        run the image on EKS
    └── undeploy.yml      remove the app from EKS
```

You need: a GitHub repo with this code, an AWS account, and on your laptop `terraform` and `aws`.
No Docker, no `kubectl`, no Docker Hub: your laptop only creates and destroys the cluster.
Everything that touches the app runs on a GitHub runner, started by you with the
**Run workflow** button. Nothing runs automatically.

Below, `<your-github-user>` means **your own** GitHub user name, and the repository is
`eks-oidc` (if you named your copy differently, use that name). For example, for the user
`YuvalShaul` the full repo is `YuvalShaul/eks-oidc`. The region is `us-west-2` — use the same
region everywhere.

---

## Part 1 – Teach AWS to trust GitHub (by hand, in the AWS console)

### 1a. The identity provider (once per AWS account)

AWS console → **IAM → Identity providers → Add provider**
- Provider type: **OpenID Connect**
- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- **Add provider**

This says: *"tokens signed by GitHub Actions are acceptable proof of identity in this account."*
It grants nothing yet — it only lets roles name GitHub as someone who may assume them.

### 1b. The role (the "user" is your repository)

AWS console → **IAM → Roles → Create role**
- Trusted entity type: **Web identity**
- Identity provider: `token.actions.githubusercontent.com`, Audience: `sts.amazonaws.com`
- GitHub organization: `<your-github-user>` (your GitHub user name, e.g. `YuvalShaul`)
- GitHub repository: `eks-oidc` (just the name, without the owner)
- GitHub branch: `main`
- Next → Permissions: attach **nothing** for now → Next
- Role name: `github-ci` → **Create role**

Open the role → **Trust relationships**. It looks like [iam/trust-policy.json](iam/trust-policy.json):

```json
"Condition": {
  "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
  "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<your-github-user>/eks-oidc:ref:refs/heads/main" }
}
```

That condition **is** the identity. Only a workflow running in your repo, on branch `main`,
can become this role. Without the `sub` condition, *any* GitHub repo in the world could.

Copy the role's **ARN** (`arn:aws:iam::<account-id>:role/github-ci`).

### 1c. Tell GitHub which role to ask for

GitHub repo → **Settings → Secrets and variables → Actions → Variables** tab:
- `AWS_ROLE_ARN` = the role ARN

A *variable*, not a secret: the ARN is not sensitive. Knowing it doesn't let anyone assume the
role — only a token from your repo's workflows can. Look at the **Secrets** tab: it's empty,
and it stays empty for the whole lab.

### 1d. Try it

**Actions → whoami → Run workflow.** Read the log:
- *the OIDC token's claims*: `iss` (GitHub), `aud` (`sts.amazonaws.com`), `sub`
  (`repo:<your-github-user>/eks-oidc:ref:refs/heads/main`), the workflow, the actor, and `exp` — the token
  itself is only good for a few minutes.
- *Who does AWS think we are?* → `assumed-role/github-ci/GitHubActions`. The role has no
  permissions at all, but `get-caller-identity` needs none.

Things to notice:
- `permissions: id-token: write` in the workflow. Without it, the job can't ask GitHub for a
  token. Try it: remove it, run → the credentials step fails.
- Try it broken: create a branch `test`, push it, and run **whoami** on branch `test`
  (the branch dropdown in the Run workflow box). The `sub` is now `...:ref:refs/heads/test`,
  the trust policy doesn't match, and AWS refuses: *Not authorized to perform
  sts:AssumeRoleWithWebIdentity*.

## Part 2 – An ECR repository, and permission to push (by hand, in the AWS console)

1. AWS console (region `us-west-2`) → **Elastic Container Registry → Private registry →
   Repositories → Create repository**
   - Name: `hello-flask`, tag mutability: **Mutable** (we overwrite `latest`) → **Create**
2. **IAM → Roles → github-ci → Add permissions → Create inline policy → JSON**.
   Paste [iam/ecr-push-policy.json](iam/ecr-push-policy.json), replace `REGION` and
   `ACCOUNT_ID`. Name it `push-hello-flask` → **Create policy**.

   Two statements: `ecr:GetAuthorizationToken` (log in to ECR — always `Resource: "*"`)
   and the push actions, **only on the repository `hello-flask`**.
3. Run it: **Actions → build-push → Run workflow.**
   Open the run and look at *Set up job*: it shows the runner's OS image and machine — that's
   where the build happens, not on your laptop.
4. Check ECR: `hello-flask` now has `latest` and a commit tag.

Things to notice:
- There is no login secret. *Log in to ECR* turns the 1-hour role credentials into a Docker
  password (`aws ecr get-login-password`) on the fly.
- Try it broken: create a second ECR repo `other`, change `hello-flask` to `other` in
  build-push.yml, and run it → the push is denied. The role can push to one repo only.

## Part 3 – Create the cluster (by hand, from your laptop)

```bash
aws sts get-caller-identity     # make sure these are YOUR admin credentials
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply -var-file=terraform.tfvars                 # ~15-20 minutes
```

`eks_terraform_config.tf` + `vars.tf` are the cluster from the k8s course (VPC, EKS, a node group).
`github-ci-role.tf` is new. It does **not** create the provider or the role; it only gives your
hand-made `github-ci` role two more permissions:

- **AWS (IAM):** only `eks:DescribeCluster` on this cluster
- **Kubernetes (EKS access entry):** `AmazonEKSEditPolicy`, **only in namespace `default`**

Look at the role in the IAM console again: it now has two inline policies, `push-hello-flask`
(yours) and `describe-learn-eks` (Terraform's). And under **EKS → learn-eks → Access**, you'll
find the `github-ci` role with its access policy.

The nodes need to pull the image from ECR too. They don't use `github-ci` — they have their
own role (`terraform output node_role_arn`), which the EKS module gives
`AmazonEC2ContainerRegistryReadOnly`. Two different identities: one pushes, the other pulls.

If you changed the region or the cluster name, tell GitHub too
(**Settings → Secrets and variables → Actions → Variables**): `AWS_REGION`, `EKS_CLUSTER`.

## Part 4 – Deploy from GitHub Actions

Run it: **Actions → deploy → Run workflow** (tag: `latest`). Read the log:
- *Who does AWS think we are?* → `assumed-role/github-ci/...`, not you
- *What may we do?* → yes in `default`, no in `kube-system`, no nodes
- the **job summary** shows the app URL. Open it (DNS may take 1-2 minutes the first time) and
  refresh a few times: `pod` changes — two replicas behind one load balancer.

Two layers of permission: **IAM** decides who the runner is (the trust policy) and which AWS
calls it may make (push to one ECR repo, describe one cluster); the **EKS access entry** decides
what it may do inside Kubernetes (edit namespace `default`, nothing else).

Try it broken: in IAM, edit the role's trust policy and change `refs/heads/main` to
`refs/heads/nope` → re-run deploy → the very first AWS step fails. Change it back and it works.
(That's the OIDC version of "deactivate the access key" — except there is no key.)

---

## Clean up (important – this costs money: EKS, NAT gateway, EC2, load balancer)

1. **Actions → undeploy → Run workflow.** This deletes the app and its load balancer
   (a leftover load balancer blocks deleting the VPC).
2. From your laptop:

   ```bash
   cd terraform
   terraform destroy -var-file=terraform.tfvars
   ```
3. By hand, what you created by hand:
   - ECR → delete repository `hello-flask` (with its images; storage costs a few cents a month)
   - IAM → Roles → delete `github-ci`
   - IAM → Identity providers → delete `token.actions.githubusercontent.com`
     (only if nothing else in the account uses it)
   - GitHub → delete the variables

Notice what's *not* on that list: no key to revoke, no token to delete, no secret to remove.

## Notes

- **Static keys vs OIDC.** In `eks-manual`, a leaked key works until someone revokes it, from
  anywhere. Here there's nothing to leak: the OIDC token lives minutes and only AWS's STS
  accepts it, the AWS credentials live an hour, and the role can only be assumed by your repo's
  `main` branch. The cost is a bit more setup (provider + trust policy) and understanding
  what the `sub` claim means.
- **Tighten further:** use GitHub **environments** (`sub` becomes
  `repo:<your-github-user>/eks-oidc:environment:prod`) so a deploy needs a reviewer's approval before AWS
  will even trust it.
- `AmazonEKSEditPolicy` can't create namespaces – that's why the app runs in `default`.
