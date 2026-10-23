# scripts/ - what the bootstrap phases do

These scripts run **on the gw VM** (as `ubuntu`), not on the operator host. `vcf_bootstrap.sh <json>` is the
orchestrator: it sources `/home/ubuntu/bash/variables.sh` (rendered by `userdata.py`) and `functions.sh`, logs in to VCD,
checks that DNS (bind9) and NTP (chrony) are running, then runs each phase below **as its own `bash <phase>.sh`
process**, in this order. A non-zero exit of any phase aborts the whole pipeline (`log_notify "ERROR: <phase>.sh failed"`).
All phases append to the same `/home/ubuntu/vcf_bootstrap.log`.

Phases are self-contained and idempotent (re-runnable): each re-sources the variables, re-logs in, and skips what already
exists. Phases marked **soft-fail** log an ERROR and exit 0, so an optional feature never aborts the pipeline.

Do not edit a phase script while it is executing (bash reads scripts incrementally; it corrupts the running copy).

```
gw-accounts -> gw-org-api -> gw-blueprint-api -> vault-pki-bootstrap -> esxi-bootstrap -> vcf-installer-bootstrap
-> vcenter-bootstrap -> nsx-bootstrap -> avi-bootstrap -> nsx-project-vpc -> supervisor-bootstrap -> k8s-bootstrap
-> git-bootstrap -> vcfa_provider_bootstrap -> vcfa_tenant_bootstrap -> supervisor-blueprint-watcher
```

## Phases

### 1. `gw-accounts.sh`
Creates one Linux account per VCF-A org on the gw (`org-1`, `org-2`, ...), SSH + password login. The password is
`VMware1!<4 hex of sha256(gw_accounts_secret + org_name)>VMware1!` (20 chars exactly: vCenter SSO caps at 20, VCFA
requires mixed character classes). The same derivation is used for the org's vCenter SSO, NSX, Avi, VCF-A, Git and
Argo accounts, so it must stay identical in every script that copies it. vApp use case only: generates the gw's WireGuard
keypair (once, never regenerated) and, per org, `/home/<org>/wireguard` (keypair + `wg0.conf`, tunnel address
`10.8.0.<N>/24`, the gw as peer). No dependency on anything else, hence first.

### 2. `gw-org-api.sh` (vApp only, opt-in, soft-fail)
Installs `gw-org-api.py` as a systemd HTTPS service (self-signed cert, basic auth) with `GET /orgs` and `POST /org`,
which hands an unassigned org (name, password, SSO domain, bookmarks of the SDDC/application services, folders to copy,
`WAF_DEMO_HOST`) to a student desktop. Enabled by `spec.vms.gw.org_api`; not set -> skipped. Config is re-read per request.
`WAF_DEMO_HOST` is derived from the `metadata.name` of the first `HTTPRoute` under `gitops/` (`<name>.<org>-gitops.<domain>`).

### 3. `gw-blueprint-api.sh` (both use cases, soft-fail)
Installs `gw-blueprint-api.py` as a systemd HTTPS service (port 8444, HMAC-authenticated `PUT /apps/state`). It receives
the "app" labels of the VMs of each org namespace (posted by the Supervisor watcher, last phase) and rewrites the enum of
one input of one VCF-A blueprint. Creates the self-signed cert, the shared HMAC secret (generated once) and `config.json`.
Enabled when any org has `blueprints.auto_update.enabled`.

### 4. `vault-pki-bootstrap.sh` (optional)
Vault on the gw (single shared instance) plus a root/intermediate PKI for cert-manager. Runs when any org has
`namespace.vault_integration` or the shared k8s cluster is enabled. Auto-unseals at service start, creates the PKI
roles, and a read-only `student-readonly` userpass login per org. Must finish before `vcfa_tenant_bootstrap` (it reads
Vault's root token and TLS cert) and `k8s-bootstrap` (ClusterIssuer).

### 5. `esxi-bootstrap.sh`
Powers on and waits for the nested ESXi VMs (sized by `esx.dynamic_sizing_mgmt`, which scales with org count), marks
their disks as SSD, and builds the `hostSpecs` JSON handed to the next phase through a temp file. (sddc use case: ejects
the kickstart ISOs; it talks to the external vCenter through govc.)

### 6. `vcf-installer-bootstrap.sh`
Patches the VCF Installer appliance (lcm/domainmanager config -> staging depot + license service, through `su -` +
expect), exchanges license credentials for an activation code, downloads the INSTALL bundles (only those whose
`toVersion` starts with `<vcf_version_full>.`, i.e. base `9.1.1.0.*`), validates the SDDC spec (`POST /v1/sddcs/validations`),
then submits and polls the SDDC build until `COMPLETED_WITH_SUCCESS`. The build itself can take many hours; silence is normal.

### 7. `vcenter-bootstrap.sh`
Against the newly built nested vCenter (govc): creates the extra port groups and silences the vSAN health alarms a
nested vSAN can never pass (they block Supervisor enablement).

### 8. `nsx-bootstrap.sh`
NSX Manager readiness, uplink profile for the edge, transport zones, the external VLAN segment, the host transport
node profile update, disables the OVF validation flag, deploys the edge nodes (fp-eth0 = overlay, fp-eth1 = external),
waits for them, creates the edge cluster, then the Tier-0 (with its edge cluster association) and the overlay segments.

### 9. `avi-bootstrap.sh`
Deploys the Avi controller through SDDC Manager (bundle pinned by `spec.sddc.avi.version`) then configures it: NSX
cloud integration, service engine group(s), IPAM (VIP network and pool), the **DNS profile** (domains for the base
subdomain plus three per org: `<org>.<domain>`, `<org>-vks.<domain>`, `<org>-gitops.<domain>`), the DNS virtual
service, license/JWT, the traffic-generator helper, system WAF policies (`clone_waf_policy`, including
`System-WAF-Policy-Enforcement-Php2shell` with the pre-CRS rules from Broadcom KB 460068), and the Avi upgrade.

### 10. `nsx-project-vpc.sh`
NSX multi-tenancy: per non-default project the Tier-0/edge-cluster project settings, transit-gateway attachments,
inter-VPC transit gateway IP blocks, VPC connectivity profiles and VPC service profiles (VCF 9.1 only; the Avi
onboarding workflow of the reference script is dropped).

### 11. `supervisor-bootstrap.sh`
Subscribes the vCenter content library, enables the Supervisor (NSX_VPC networking, vSAN storage policy, waits for
RUNNING/READY plus an extra settle time), installs the Supervisor Services (Harbor, ArgoCD) and pushes the ISO-delivered
images to Harbor (preload list in the CR), and renders the Supervisor auth helper scripts and `harbor_rewrite_images.sh`.

### 12. `k8s-bootstrap.sh` (optional, soft-fail)
`spec.sddc.k8s.enabled`: one control-plane + N worker VMs from the Ubuntu cloud-image OVA (govc, static IPs,
cloud-init), kubeadm, Antrea (NodePortLocal), Gateway API CRDs, AKO (Avi), local-path-provisioner, cert-manager and a
ClusterIssuer backed by the gw's Vault PKI (AppRole). Shared platform for Helm releases.

### 13. `git-bootstrap.sh` (optional, soft-fail)
`spec.sddc.k8s.git.enabled`: Gitea (Helm, from the gw-tools ISO; image from Harbor) on the shared cluster, exposed through
an AKO Gateway/HTTPRoute at `git.<avi subdomain>.<domain>` with a cert-manager certificate. Creates one private Gitea user
and one private repo per org, then verifies one org cannot see another's repo.

### 14. `vcfa_provider_bootstrap.sh`
VCF Automation **provider-portal** half (provider bearer token): regions, external IP spaces, provider gateways,
shared content libraries and their OVA items, then a per-org loop (see recap). Everything the tenant script needs
already exists on exit. No-op if `spec.sddc.vcf_a` is unset.

### 15. `vcfa_tenant_bootstrap.sh`
VCF Automation **org-portal** half (org-scoped OAuth token obtained by jwt-bearer exchange, one per org): supervisor
namespaces, Vault integration, VKS clusters, ArgoCD, blueprints, and the per-org vCenter / Avi / NSX / Harbor
accounts (see recap).

### 16. `supervisor-blueprint-watcher.sh` (last, soft-fail)
Needs the org namespaces, their labels and the uploaded blueprints, hence last. Creates a provider-only vSphere
namespace (`vm-watcher`), a ServiceAccount + HMAC Secret + cert and code ConfigMaps in it, namespaced Role/RoleBinding in
every org namespace of an org with `blueprints.auto_update`, the watcher Deployment, and checks that the watcher posted a
state and that each project has the named blueprint.

### Manual tool: `vcfa_tenant_cleaning.sh` (not part of the pipeline)
Run by hand on the gw to reset orgs: `vcfa_tenant_cleaning.sh [--org <name>] [--yes] [--dry-run] [--no-recreate]`.
Without `--org` it takes every org still free in gw-org-api (assigned ones are left alone); with `--org` that org only,
even if assigned. It always prints a destructive-action warning and asks for `yes` (`--yes` skips the prompt).
Per org: claim it (`POST /org`, or a root-created `.assigned` for `--org`), reset the Gitea repo to the sample
ConfigMap only, set AKO `deleteConfig=true` in each VKS cluster and wait for the Avi tenant to be empty, delete the
blueprint deployments, the VKS cluster(s) and all namespaces. Then it reruns `vcfa_tenant_bootstrap.sh` to recreate
the namespace and VKS cluster, and releases the cleaned orgs (an org whose cleaning failed stays claimed). Log:
`/home/ubuntu/vcfa_tenant_cleaning.log`.

### Helpers
`functions.sh` (log_notify, vcd_login, vcfa_login/vcfa_api, avi/nsx/vcenter API helpers, `find_org_manifest`).
`gw-org-api.py`, `gw-blueprint-api.py`, `supervisor-blueprint-watcher.py`: the runtimes behind phases 2, 3 and 16.

## Recap: what is done per org

An "org" is one entry of `vcf_a_organizations` (expanded from `organization_templates`, e.g. `org-1` ... `org-16`).
Scripts not listed do nothing per org.

| Script | Per-org work |
|---|---|
| `gw-accounts.sh` | Linux account `<org>` with the derived password; `/home/<org>/wireguard` (700) with keypair, `wg0.conf` (tunnel `10.8.0.<N>/24`) and the wg-quick init script. |
| `gw-org-api.sh` | Adds the org to the assignable list (name + derived password, bookmarks, folders, `WAF_DEMO_HOST`); `POST /org` assigns one org to one student desktop. |
| `vault-pki-bootstrap.sh` | Read-only `student-readonly` Vault userpass login `<org>` (one per org). |
| `avi-bootstrap.sh` | Three DNS service domains per org: `<org>.<domain>`, `<org>-vks.<domain>`, `<org>-gitops.<domain>`. (The Avi tenant itself is created by VCF-A, see provider script.) |
| `git-bootstrap.sh` | Gitea user `<org>` (derived password) owning one private repo `<org>/<git_repo_name>`. |
| `vcfa_provider_bootstrap.sh` | Renders the GitOps manifests (`gitops/*/*.yaml`, hostnames `<route>.<org>-gitops.<domain>`; existing files are kept) and the demo yaml (`<org>-vks.<domain>`) into `/home/<org>/`; creates the VCF-A **organization**, its **vDC** (CPU/memory/storage limits), VM classes, **regional networking settings** (NSX project, with a delete+recreate retry if it is not really backed), the **Avi setting** (PROVIDER_MANAGED tenant + quota + SEG, when `enable_avi`), and the **org admin user** `<org>` (Organization Administrator). Skips what already exists. |
| `vcfa_tenant_bootstrap.sh` | Per org, with a fresh org-scoped token: **supervisor namespace** (PROVIDER_MANAGED orgs; class, limits, VM Service content library binding); **Vault integration** (cert-manager token Secret + Issuer in the namespace, if `vault_integration`); **VKS cluster** (1 per org) then waits for Available, fetches its kubeconfig, sets pod security and the `cert01` TLS secret; **ArgoCD** in that VKS cluster (`argocd.<org>-vks.<domain>`, if enabled); **blueprints** created and released in the org's project; **accounts**: vCenter SSO `<org>@<sso domain>` scoped to the org's namespace (siblings NoAccess), Avi `Tenant-Admin` `<org>` in tenant `<org>`, NSX node user `<org>` (auditor), Harbor read-only user `<org>`. |
| `supervisor-blueprint-watcher.sh` | Role + RoleBinding in each org namespace (auto_update orgs only) and a target entry in `blueprint-watcher-targets`. |

All per-org accounts share the single derived password of `gw-accounts.sh`.
