# Shutdown and startup of the nested VCF lab: the recipe

First full run on the SDDC use case (nested VCF 9.1.1.0100 on an external vCenter), 2026-11-16. Written from what actually ran
(log: `~/shutdown-run/restore.txt` on the SDDC gw), to be reused for the vApp use case and, later, automated as `vcf_shutdown.sh` /
`vcf_startup.sh` and the operator lifecycle actions. Facts below were observed, not assumed; anything not verified says so.
The order follows the HOL `Shutdown.zip` (VCFshutdown.py) adapted to this lab; the zip has **no startup**, so the startup is ours.

## 0. Result in one paragraph
Shutdown phases 1-14 took **1 h 30** (13:31 to 15:00), of which the vSAN flush was 45 minutes and did **not** finish (ceiling reached).
Cold start to "everything powered on and answering" took about **45 minutes** (15:06 to ~15:50). vSAN came back healthy with the unflushed
write buffer, VSP recovered by itself, WCP started by itself and powered the Supervisor VM on by itself. Two real problems on startup:
(a) NSX edge placement and the Avi controller started before the fabric was whole (see 6), (b) the Supervisor's AKO could not find
`avi-secret` because WCP configured Avi before it was reachable (fixed by restarting WCP, see 7).

## 1. Inventory of the lab (names are `<basename>-...`, basename `sddc01`)
Underlay (external vCenter): 4 nested ESX VMs `sddc01-mgmt-esx01..04` (32 vCPU / 160 GiB), the VCF Installer VM, the gw.
Nested vCenter: `sddc01-vc01`, NSX manager `sddc01-nsx02` (VIP `.14`), edges `edge-01/02`, Avi controller `sddc01-avi-node0` + 3 SEs `vcf_Avi-se-*`,
SDDC Manager `sddc01-sddcm`, VSP `sddc01-vsp01-*` (3: 1 control-plane, 2 workers), VCF Operations `sddc01-ops01`, `sddc01-collector`, `sddc01-license`,
VCF Automation `sddc01-auto-platform-*` (single-node k8s), Supervisor `SupervisorControlPlaneVM (1)` + 14 vSphere pod VMs (Harbor etc.), shared k8s `k8s-shared-cp1/w1/w2`.
Save an inventory (name, power, host moref, IP) before and compare after. Host morefs: host-12=esx01, host-25=esx02, host-26=esx03, host-27=esx04.

## 2. Preconditions
- Remove the VCF-A orgs first (`vcfa_org.sh delete --all`): no VKS clusters, no per-org Avi objects, nothing to pause. Needs `--force` for an org held by a student.
  Found and fixed while doing this: deployments must go before waiting for Avi to empty; PVCs left in the namespace (AKO's log volumes) must be removed
  before the namespace; Avi certificates must go child before parent. All in `vcfa_org.sh`.
- Nothing running on the gw (no bootstrap phase, no `vcfa_org.sh`).
- For the SDDC use case the gw is the lab's DNS/NTP and must stay up until the end; for the vApp the operator powers it (see 8).

## 3. Shutdown: phases, commands, corrections, timings
Control channel: nested vCenter through `govc` (administrator@vsphere.local, lab password) until phase 10; then each ESX host directly
(`https://<host>`, root, same password). ESX ssh offers only keyboard-interactive (`-o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no`).

| # | What | How | Observed |
|---|---|---|---|
| 1 | inventory | `govc find / -type m` + `vm.info -json` on both vCenters | 41 VMs |
| 2 | VCF Automation | ssh `vmware-system-user` (sudo), `KUBECONFIG=/etc/kubernetes/super-admin.conf kubectl scale deployment vmsp-operator -n vmsp-platform --replicas=0` (the zip says `-n vmsp`: wrong here), then `govc vm.power -s` | VM off in 137 s |
| 3 | VSP graceful stop | Broadcom `vcf_services_runtime_shutdown.sh --node-ip <control-plane node> --yes --skip-snapshot-check` (KB 440874; **Broadcom Confidential, keep out of public repos**). Use the control-plane node (`/api/v1/components` answers 200); a worker answers 404. No `--poweroff-vms`. Needs vCenter up | task Succeeded in about 4 min |
| 4a | stop WCP | `ssh root@<vc> 'shell vmon-cli -k wcp'` (root lands in the appliance shell: **`shell` prefix needed**) | STOPPED, start type stays AUTOMATIC |
| 4b | Supervisor VM | vCenter refuses (NoPermission): connect **directly to its ESX host** and `govc vm.power -s` | off in 106 s |
| 5 | shared k8s | guest shutdown, workers then control plane | 20 s |
| 6 | VSP VMs | guest shutdown (after the script) | 109 s |
| 7 | Avi | SEs, then the controller (controller is slow: about 2.5 min) | |
| 8 | NSX | edges, then manager | 31 s, 92 s |
| 9 | Operations | collector, ops01, license | under a minute each |
| 10 | SDDC Manager, then **vCenter last** | guest shutdown; verify the vCenter off from its host | 26 s, 16 s |
| 11 | audit | connect to each host, list powered-on VMs | 14 Supervisor pod VMs left |
| 11b | pod VMs | they are `crxPod1Guest`: **no VMware Tools, guest shutdown refused**. Controlled `vm.power -off` per host, Harbor database last | 14 off; they were recreated on startup |
| 12 | vSAN flush (OSA only; ESA needs none: `esxcli vsan cluster get` shows `vSAN ESA Enabled`) | enable ssh (`govc host.service start TSM-SSH`, it was off), `echo y \| vsish -e set /config/LSOM/intOpts/plogRunElevator 1` on every host (no `yes` binary on ESX), completion see below, then set it back to 0 | see below |
| 13 | power off the 4 hosts | `govc host.shutdown -f` per host, 5 s apart, then verify the host VMs are `poweredOff` on the underlay | 129 s |
| 14 | Installer VM | guest shutdown on the underlay | 15 s |
| 15 | gw | `shutdown -h` (SDDC); vApp: the operator via VCD | |

**vSAN flush, the one that did not complete.** The zip polls `/storage/lsom/elevatorRunning`; **that path does not exist on 9.1.1** (`mal-formed path`),
and a script that reads "not 1" as "done" reports success after 1 second (it happened to me: I withdrew that result). What works: completion
= the capacity disk's write counter stops growing on every host (`esxcli storage core device stats get -d <capacity device>`, "Write Operations"
per 30 s; the cache disk is read at the same time). All four hosts settled on a flat ~4,800 operations/30 s (~8 MB/s each, a throughput ceiling of
the lab's nested storage) and never went quiet in 45 minutes (~20/18/10/10 GB destaged). We followed the zip: stop at its 45-minute ceiling and
power off anyway. The write buffer is persistent: **the first start worked, vSAN healthy, no resync, no visible delay**. For the vApp, size the
wait to the storage throughput, or accept the ceiling.

## 4. Startup: order, gates, commands, timings
Gate rule learned the hard way: **start Avi (controller and SEs together) only when the NSX fabric is fully functional** (see 6).

| # | What | How | Observed |
|---|---|---|---|
| 0 | gw up | `systemctl is-active bind9 chrony wg-quick@wg0`, `chronyc tracking`, `dig @127.0.0.1 <lab names>` | up in 2 min |
| 1 | 4 ESX VMs together | underlay `govc vm.power -on`; wait https on each; `govc host.esxcli vsan cluster get` (4 members, HEALTHY) and `vsan debug resync summary get` (0), datastore free | hosts 74 s, vSAN 4/4, 0 resync |
| 2 | vCenter | power on **directly from its host** (no vCenter yet); wait REST login, then `/sdk` (`govc about`: 503 for ~1 min after the login works), hosts connected, 36 VMs known | about 3 min |
| 3 | NSX manager | via vCenter; poll **the node IP** `/api/v1/cluster/status` (the VIP appears later) until STABLE | about 8 min |
| 3b | edges | via vCenter; poll transport-node status UP and `tunnel_status.down_count` 0 for edges **and hosts**. If an edge is DEGRADED with tunnels to host TEPs down, vMotion it to the host it had before the shutdown (it went UP in 20 s) | edges 5-10 min |
| 4 | **Avi controller + 3 SEs together**, after the gate | controller API takes about 10 min to answer; SEs connect afterwards | see 6 |
| 5 | SDDC Manager + VSP VMs | together; VSP recovers by itself (nodes Ready, components Running) per the KB | 3-4 min |
| 6 | Operations + VCF Automation | together; VCF Automation k8s node Ready in about 5 min. `vmsp-operator` needs **no** scale-up (it was already 1/1) | |
| 7 | Supervisor | WCP is AUTOMATIC, starts after vpxd and powers the Supervisor VM on itself (Supervisor API answered with 5 Ready nodes at 15:48). **Then restart WCP once Avi is up** (`shell vmon-cli -r wcp`; see 7) and wait 10-15 min until `kubernetes=READY`, the AKO pods are Running and Harbor health is 200 | AKO settled ~11 min after the restart |
| 8 | shared k8s | vCenter power on; Gitea answered 200 | 3 min |
| 9 | orgs | `vcfa_org.sh add --all` (not run yet) | |
| 10 | stop ssh on the hosts again | `govc host.service stop TSM-SSH` | |

## 5. Things that did NOT need doing (the zip's version was wrong or unnecessary here)
`-n vmsp` namespace (it is `vmsp-platform`), the `uncordon` step (node was not cordoned), the manual Supervisor power-on, the `vmsp-operator` scale-up,
`elevatorRunning` polling, `yes |` (not on ESX), `tr` (not on ESX), the guest shutdown of the pod VMs.

## 6. The Avi / edge lesson (the cost of starting too early)
At 15:22 the Avi controller was powered on right after the NSX manager went STABLE, and the SEs only 4 minutes later (15:27), while `edge-02`
(placed by DRS on esx01; **both edges had been on esx03 before the shutdown**) had all 8 tunnels to the host TEPs down. The controller needed
~10 min before its API answered; it saw its SEs as not connected and, because the SE group has `buffer_se=1`, **deployed a 4th SE**
(`vcf_Avi-se-qeqob`, created 15:33). After `edge-02` was vMotioned back to esx03 (UP in 20 s) all 4 SEs went OPER_UP (about 8 min later).
Rule for the automation: do not start the Avi controller or its SEs until (NSX manager STABLE) and (both edges UP) and (all host transport nodes UP, 0 tunnels down).
Restore the pre-shutdown edge placement first (record it in the shutdown inventory). The extra SE can be deleted from Avi once everything is stable.

## 7. Open at the time of writing (not resolved)
- **Supervisor AKO: RESOLVED by restarting WCP, with a delay.** Symptom after the cold start: `ako-controller-manager` and `ako-crd-operator` crash-looped,
  the CRD operator's error was `Failed to get avi-secret: secrets "avi-secret" not found` -> `FATAL Failed to initialize WCP cluster configuration`,
  the Supervisor reported `config=RUNNING kubernetes=WARNING`, Harbor's virtual service was OPER_DOWN and Harbor answered nothing. Cause (consistent with
  everything observed): WCP started at ~15:17 (automatically, after vpxd) and configured its load balancer while the Avi controller was not reachable yet
  (its API answered ~15:33); it does not retry. Fix: `ssh root@<vc> 'shell vmon-cli -r wcp'` once Avi is up and stable (done 15:54). Nothing changed for
  4-5 minutes (AKO's own back-off), then at ~16:05 both AKO pods were Running, the Supervisor reported `kubernetes=READY`, Harbor health returned 200 and all 9 Avi
  virtual services were OPER_UP. **Add to the startup: after the Avi gate is satisfied and the SEs are UP, restart WCP and wait about 10-15 minutes for AKO.**
  (Better still, if the vApp operator can order it: do not let WCP start before Avi; WCP is AUTOMATIC with the vCenter, so the restart is the practical fix.)
- **gw: Vault did not start after the gw reboot (found when `add --all` could not write the per-org Vault logins).** `vault.service` failed 3 times at boot: `Failed to execute /usr/local/bin/vault-unseal.sh: Permission denied` (203/EXEC): the ExecStartPost helper is root:root 700 and the unit runs as the vault user. Fixed on the gw with `ExecStartPost=+...` in `/etc/systemd/system/vault.service.d/unseal.conf` + `daemon-reload` + `reset-failed` + `start vault` (then initialized, unsealed, health 200), and in `vault-pki-bootstrap.sh` for new gws. **Startup check to add (step 0): `systemctl is-active vault` and `curl -sk https://127.0.0.1:8200/v1/sys/health` = 200 before anything per-org.** After that, re-run `vcfa_org.sh add <org>` for the orgs added while Vault was down (Vault logins, cert-manager Issuer secret).
- VCF Automation: 8 pods `Unknown` in namespace `prelude` and `vcfa-service-manager` CrashLoopBackOff (137 restarts, probably pre-existing); the provider portal is healthy per the user.
- A 4th Avi SE exists (see 6). Old Supervisor pod objects remain as `ProviderFailed`/`NotFound` (tombstones of the hard-stopped pods).

## 8. What changes for the vApp use case
- Power operations go through **VCD** (the operator already has `power_on_vm`, `undeploy_vm`, `undeploy_vapp`; the gw already powers ESX VMs through VCD): no underlay vCenter, no credentials to carry. The operator powers the gw on first and waits for it, so the manual hand-off of this run disappears.
- Five hosts (`esx05` is the dedicated host for vCenter and VCF Automation) and names come from the spec: the scripts must loop over `names_esxi`, not hard-code four. Edge/VM placement and DRS rules differ (dedicated host rules): record and restore placement.
- Same VCF 9.1.1 stack: the order, the VSP script, the `shell` prefix, the Supervisor through its host, CRX pods needing a power-off, `vmsp-platform`, the flush by disk counters, and the Avi gate all carry over.
- Lifecycle plan: operator `delete-vcfa-orgs` -> gw `shutdown-platform` (phases 2-14, reports `ready-for-poweroff`) -> operator undeploys the vApp -> template capture. Startup: operator powers the vApp on (gw first) -> gw `startup-platform` (gated steps 1-8) -> `add-vcfa-orgs`.
- A captured template carries this disk: reset `vcf_status.json`, the diagnostics state, and decide what to do about SSH state on the hosts.

## 9. Evidence on the SDDC gw (`~/shutdown-run/`)
`restore.txt` (timeline), `STARTUP-RUNBOOK.md` (with the lessons), `inventory-before.tsv`, `nested-inventory-before-vc-off.tsv`, `audit-hosts*.tsv`,
`vsan-elevator2.log` (the flush, polls every 30 s), `vsp-shutdown.log`, helper scripts `health.sh`, `ako.sh`, `ako2.sh`, `wcp.sh`.
