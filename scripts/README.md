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
-> vcfa-stabilize -> vcenter-bootstrap -> nsx-bootstrap -> avi-bootstrap -> nsx-project-vpc -> supervisor-bootstrap -> k8s-bootstrap
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

### 7. `vcfa-stabilize.sh` (soft-fail) + `vcfa-stabilize-node.sh`
Runs right after the SDDC build, as soon as VCF Automation exists and before anything talks to it. Finds the single VCF-A
node (the address of `spec.vcf_automation.ip_pool` that answers SSH and has the control-plane static pod manifests; the
control-plane VIP takes one of the pool addresses too), logs in as `vmware-system-user` (override with
`vcfa_ssh_user`) with the VCF-A admin password (`generic_password`; sshpass environment variable and sudo stdin, never a
command line), copies `vcfa-stabilize-node.sh` over and runs it as root. The node script (idempotent; `status` is
read-only, `apply` waits a bounded time for load1 < 20 first) sets what was measured to keep VCF-A up through its own CPU
bursts (see "VCF-A stability" below): leader election 60s/40s/6s for kube-controller-manager, kube-scheduler,
vsphere-cpi and Envoy Gateway, kube-vip 60/40/6 + preserve for both the control-plane static pod and the gateway VIPs,
etcd CPU request 2500m + hourly compaction, probe tolerance for the Envoy Gateway controller and the two gateway proxies,
and a CPU request for the BestEffort UI deployments. Static manifests are backed up to `/root/manifest-bak` and edited
once (the etcd edit restarts the API server for ~2 minutes); objects the operator or Flux revert are re-asserted by a
60-second systemd keeper (`vcfa-live-keeper`). Soft-fail: a node that cannot be found or logged in to, a layout with more
than one control-plane node, or a remote error is logged and the pipeline goes on. `vcfa_stabilize=false` skips it.
Not done here: any VM CPU/memory resize (the results below were measured at 32 vCPU / 128 GiB).

### 8. `vcenter-bootstrap.sh`
Against the newly built nested vCenter (govc): creates the extra port groups and silences the vSAN health alarms a
nested vSAN can never pass (they block Supervisor enablement).

### 9. `nsx-bootstrap.sh`
NSX Manager readiness, uplink profile for the edge, transport zones, the external VLAN segment, the host transport
node profile update, disables the OVF validation flag, deploys the edge nodes (fp-eth0 = overlay, fp-eth1 = external),
waits for them, creates the edge cluster, then the Tier-0 (with its edge cluster association) and the overlay segments, and finally the single shared read-only NSX node user (`student`) that every org uses (NSX caps local node users, so none per org).

### 10. `avi-bootstrap.sh`
Deploys the Avi controller through SDDC Manager (bundle pinned by `spec.sddc.avi.version`) then configures it: NSX
cloud integration, service engine group(s), IPAM (VIP network and pool), the **DNS profile** (domains for the base
subdomain plus three per org: `<org>.<domain>`, `<org>-vks.<domain>`, `<org>-gitops.<domain>`), the DNS virtual
service, license/JWT, the traffic-generator helper, system WAF policies (`clone_waf_policy`, including
`System-WAF-Policy-Enforcement-Php2shell` with the pre-CRS rules from Broadcom KB 460068), and the Avi upgrade.

### 11. `nsx-project-vpc.sh`
NSX multi-tenancy: per non-default project the Tier-0/edge-cluster project settings, transit-gateway attachments,
inter-VPC transit gateway IP blocks, VPC connectivity profiles and VPC service profiles (VCF 9.1 only; the Avi
onboarding workflow of the reference script is dropped).

### 12. `supervisor-bootstrap.sh`
Subscribes the vCenter content library, enables the Supervisor (1 or 3 control-plane VMs from `supervisor_control_plane_count`, NSX_VPC networking, vSAN storage policy, waits for
RUNNING/READY plus an extra settle time), installs the Supervisor Services (Harbor, ArgoCD) and pushes the ISO-delivered
images to Harbor (preload list in the CR), and renders the Supervisor auth helper scripts and `harbor_rewrite_images.sh`.

### 13. `k8s-bootstrap.sh` (optional, soft-fail)
`spec.sddc.k8s.enabled`: one control-plane + N worker VMs from the Ubuntu cloud-image OVA (govc, static IPs,
cloud-init), kubeadm, Antrea (NodePortLocal), Gateway API CRDs, AKO (Avi), local-path-provisioner, cert-manager and a
ClusterIssuer backed by the gw's Vault PKI (AppRole). Shared platform for Helm releases.

### 14. `git-bootstrap.sh` (optional, soft-fail)
`spec.sddc.k8s.git.enabled`: Gitea (Helm, from the gw-tools ISO; image from Harbor) on the shared cluster, exposed through
an AKO Gateway/HTTPRoute at `git.<avi subdomain>.<domain>` with a cert-manager certificate. Creates one private Gitea user
and one private repo per org, then verifies one org cannot see another's repo.

### 15. `vcfa_provider_bootstrap.sh`
VCF Automation **provider-portal** half (provider bearer token): regions, external IP spaces, provider gateways,
shared content libraries and their OVA items, then a per-org loop (see recap). Everything the tenant script needs
already exists on exit. No-op if `spec.sddc.vcf_a` is unset. Starts with a **health gate** (`vcfa_health_gate`): it waits for 5
consecutive answers of the VCF-A gateway in under 3 s (`vcfa_gate_good`, `vcfa_gate_limit_sec`, `vcfa_gate_max_wait_sec` 900,
`vcfa_health_gate=false` to skip) and then goes on even if the platform never calmed down.

### 16. `vcfa_tenant_bootstrap.sh`
VCF Automation **org-portal** half (org-scoped OAuth token obtained by jwt-bearer exchange, one per org): supervisor
namespaces, Vault integration, VKS clusters, ArgoCD, blueprints, and the per-org vCenter / Avi / NSX / Harbor
accounts (see recap).
The VKS clusters are created and finished **one org at a time** (create, wait for Available, kubeconfig, pod security,
`cert01`, ArgoCD, then the next org), because 16 clusters bootstrapping together overloaded the single-node VCF Automation
and the Supervisor. A "calm gate" waits before each new cluster until the provider API and the Supervisor API answer fast
(`vks_calm_limit_sec` 3, `vks_calm_max_wait_sec` 600, `vks_calm_gate=false` to disable); a catch-up pass at the end retries any
cluster that was not Available the first time. `vks_sequential=false` restores the old create-all-then-wait behaviour;
`vks_pause_between_orgs_sec` (default 20) spaces the orgs. These are environment variables of the script.

### 17. `supervisor-blueprint-watcher.sh` (last, soft-fail)
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

## VCF-A stability (nested lab)

Measured on the 16-org nested lab, VCF-A as one node (32 vCPU, 128 GiB), 2026-10-23. What `vcfa-stabilize` does and does not fix:

- **Symptom:** every 12-26 minutes the node load goes from ~10 to 100-500 for ~30 s (hundreds of runnable tasks, 0% idle,
  0% steal in the last captures). Un-tuned, each burst made leader-elected controllers miss their lease (the API server
  stalls for 10 s or more), `kube-vip` dropped the control-plane and gateway VIPs, and pods restarted in waves.
- **Fixed:** with the settings above the platform survived bursts up to load 502 with no restart of kube-controller-manager,
  kube-scheduler, kube-vip or the gateway proxies and no failed VIP probe over 4+ hours (only Envoy Gateway's own controller
  restarted before its lease setting was held by the keeper). The bursts themselves are **not** fixed.
- **What a burst is made of:** a crowd of short-lived processes - the kubelet's exec probes (`runc exec`, `kubectl`,
  `rabbitmq-diagnostics` which starts a whole Erlang VM each time) and dozens of `postgres` backends, `iptables` restores,
  `ytt`. Once the node stalls for a few seconds, the probes pile up and deepen the stall. What starts the first stall is
  unknown.
- **Ruled out:** storage latency (2-3 ms), DRS churn, VCD snapshots, a VDC CPU limit, Velero and the backup CronWorkflows
  (only the etcd backup every 3 h and the hourly WAL cleanup run, neither matches), the host shared with the Supervisor
  control-plane VM (bursts continued with them on different hosts). Early captures did show hypervisor steal (4-25 %) on
  an overcommitted host; moving the VM and giving it 32 vCPU removed it.
- **Not worth doing:** the Kyverno cleanup webhook patch (Kyverno rewrites it itself), more tuning of exec probes across
  the platform (vmsp-operator reverts it).
- **Remaining levers are capacity, not tuning:** more CPU headroom for the nested hosts (a CPU reservation or shares for the
  ESX VMs is a question for the VCD admin) or a second VCF-A node.

## Recap: what is done per org

An "org" is one entry of `vcf_a_organizations` (expanded from `organization_templates`, e.g. `org-1` ... `org-16`).
Scripts not listed do nothing per org.

| Script | Per-org work |
|---|---|
| `gw-accounts.sh` | Linux account `<org>` with the derived password; `/home/<org>/wireguard` (700) with keypair, `wg0.conf` (tunnel `10.8.0.<N>/24`) and the wg-quick init script. |
| `gw-org-api.sh` | Adds the org to the assignable list (name + derived password, bookmarks, folders, `WAF_DEMO_HOST`; the NSX bookmark carries the shared `student` login); `POST /org` assigns one org to one student desktop. |
| `vault-pki-bootstrap.sh` | Read-only `student-readonly` Vault userpass login `<org>` (one per org). |
| `avi-bootstrap.sh` | Three DNS service domains per org: `<org>.<domain>`, `<org>-vks.<domain>`, `<org>-gitops.<domain>`. (The Avi tenant itself is created by VCF-A, see provider script.) |
| `git-bootstrap.sh` | Gitea user `<org>` (derived password) owning one private repo `<org>/<git_repo_name>`. |
| `vcfa_provider_bootstrap.sh` | Renders the GitOps manifests (`gitops/*/*.yaml`, hostnames `<route>.<org>-gitops.<domain>`; existing files are kept) and the demo yaml (`<org>-vks.<domain>`) into `/home/<org>/`; creates the VCF-A **organization**, its **vDC** (CPU/memory/storage limits), VM classes, **regional networking settings** (NSX project, with a delete+recreate retry if it is not really backed), the **Avi setting** (PROVIDER_MANAGED tenant + quota + SEG, when `enable_avi`), and the **org admin user** `<org>` (Organization Administrator). Skips what already exists. |
| `vcfa_tenant_bootstrap.sh` | Per org, with a fresh org-scoped token: **supervisor namespace** (PROVIDER_MANAGED orgs; class, limits, VM Service content library binding); **Vault integration** (cert-manager token Secret + Issuer in the namespace, if `vault_integration`); **VKS cluster** (1 per org) then waits for Available, fetches its kubeconfig, sets pod security and the `cert01` TLS secret; **ArgoCD** in that VKS cluster (`argocd.<org>-vks.<domain>`, if enabled); **blueprints** created and released in the org's project; **accounts**: vCenter SSO `<org>@<sso domain>` scoped to the org's namespace (siblings NoAccess), Avi `Tenant-Admin` `<org>` in tenant `<org>`, Harbor read-only user `<org>` (no NSX user: one shared account, see `nsx-bootstrap.sh`). |
| `supervisor-blueprint-watcher.sh` | Role + RoleBinding in each org namespace (auto_update orgs only) and a target entry in `blueprint-watcher-targets`. |

All per-org accounts share the single derived password of `gw-accounts.sh`.
