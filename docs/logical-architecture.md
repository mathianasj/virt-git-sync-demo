# Logical Architecture (Cloud-Agnostic)

This document provides abstracted architecture diagrams showing the logical components and network topology without cloud provider-specific details.

## High-Level Architecture

```mermaid
flowchart TB
    User[User/Operator]
    User --> Bastion[Bastion Host<br/>SSH Jump Host<br/>Deployment Tools]
    
    Bastion --> CoreRouter
    
    subgraph HubCluster["Hub Cluster Network (10.0.0.0/16)"]
        HubCP[Control Plane<br/>3 nodes]
        HubWorkers[Standard Workers<br/>3 nodes]
        HubBM[Bare Metal Workers<br/>CNV-enabled nodes]
        HubToR[Hub ToR Switch<br/>BGP-enabled<br/>ASN: 64512]
        ACM[Red Hat ACM<br/>Multi-Cluster Management]
        GitOps[OpenShift GitOps]
        HubGit[HA Git Server<br/>Active instance<br/>Shared storage]
        
        HubCP --> HubToR
        HubWorkers --> HubToR
        HubBM -.BGP Peering.-> HubToR
    end
    
    subgraph MgdCluster["Managed Cluster Network (10.1.0.0/16)"]
        MgdCP[Control Plane<br/>3 nodes]
        MgdWorkers[Standard Workers<br/>3 nodes]
        MgdBM[Bare Metal Workers<br/>CNV-enabled nodes]
        MgdToR[Managed ToR Switch<br/>BGP-enabled<br/>ASN: 64513]
        MgdGit[HA Git Server<br/>Active instance<br/>Shared storage]
        VirtSync[Virt-Git-Sync Operator]
        CNV[OpenShift Virtualization<br/>KubeVirt VMs]
        ODF[OpenShift Data Foundation<br/>Ceph Storage]
        
        MgdCP --> MgdToR
        MgdWorkers --> MgdToR
        MgdBM -.BGP Peering.-> MgdToR
    end
    
    subgraph CoreNet["Core Network"]
        CoreRouter[Core Router<br/>BGP-enabled<br/>Upstream connectivity]
        Internet((Internet))
        
        CoreRouter --> Internet
    end
    
    HubCluster ~~~ MgdCluster
    
    HubToR -.BGP Peering.-> CoreRouter
    MgdToR -.BGP Peering.-> CoreRouter
    HubToR -.BGP Peering.-> MgdToR
    
    HubGit <-.Active/Active HA<br/>Database replication.-> MgdGit
    GitOps -.Syncs from.-> HubGit
    VirtSync -.Watches.-> MgdGit
    ACM -.Manages.-> MgdCP
    
    style HubBM fill:#f96,stroke:#333,stroke-width:3px
    style MgdBM fill:#f96,stroke:#333,stroke-width:3px
    style HubToR fill:#9cf,stroke:#333,stroke-width:2px
    style MgdToR fill:#9cf,stroke:#333,stroke-width:2px
    style CoreRouter fill:#9cf,stroke:#333,stroke-width:3px
    style ACM fill:#f9f,stroke:#333,stroke-width:2px
    style CNV fill:#9f9,stroke:#333,stroke-width:2px
    style HubGit fill:#fc9,stroke:#333,stroke-width:2px
    style MgdGit fill:#fc9,stroke:#333,stroke-width:2px
```

## Network Topology

```mermaid
graph TB
    subgraph "Network Architecture"
        subgraph "Hub Cluster Network (10.0.0.0/16)"
            HubNodes[OpenShift Nodes<br/>10.0.11-13.0/24<br/>Control Plane + Workers]
            
            HubToR[Hub ToR Switch<br/>VLAN 10: 10.0.0.0/16<br/>BGP ASN: 64512]
            
            HubNodes --> HubToR
        end
        
        subgraph "Managed Cluster Network (10.1.0.0/16)"
            MgdNodes[OpenShift Nodes<br/>10.1.11-13.0/24<br/>Control Plane + Workers]
            
            MgdToR[Managed ToR Switch<br/>VLAN 11: 10.1.0.0/16<br/>BGP ASN: 64513]
            
            MgdNodes --> MgdToR
        end
        
        subgraph "Shared VM Overlay Network (192.168.100.0/24)"
            VMCIDR[Shared Layer 2 Network<br/>CUDN: ClusterUserDefinedNetwork<br/>Same prefix advertised by both clusters<br/>Automatic failover via BGP]
            
            HubVMs[VMs on Hub<br/>192.168.100.x]
            MgdVMs[VMs on Managed<br/>192.168.100.x]
            
            HubVMs --> VMCIDR
            MgdVMs --> VMCIDR
        end
        
        subgraph "Core Network"
            CoreRouter[Core Router<br/>Aggregates routes<br/>Upstream connectivity]
            
            HubToR -.BGP Peering.-> CoreRouter
            MgdToR -.BGP Peering.-> CoreRouter
            HubToR -.BGP Peering.-> MgdToR
        end
        
        HubToR <-.Advertises VM Routes.-> VMCIDR
        MgdToR <-.Advertises VM Routes.-> VMCIDR
        
        CoreRouter --> Internet((Internet))
    end
    
    style HubToR fill:#9cf,stroke:#333,stroke-width:3px
    style MgdToR fill:#9cf,stroke:#333,stroke-width:3px
    style CoreRouter fill:#9cf,stroke:#333,stroke-width:3px
    style VMCIDR fill:#ff9,stroke:#333,stroke-width:2px
```

## Routing Architecture

```mermaid
graph TB
    subgraph "Worker Node Routing Strategy"
        subgraph "Standard Workers"
            StdWorker[Standard Worker Nodes<br/>General purpose compute]
            StdRoute[Default Route<br/>→ ToR Switch<br/>→ Core Network]
            
            StdWorker --> StdRoute
        end
        
        subgraph "Bare Metal Workers (CNV)"
            BMWorker[Bare Metal Worker Nodes<br/>KubeVirt workloads<br/>Nested virtualization]
            BMRoute[Default Route<br/>→ ToR Switch]
            FRRPod[FRR-K8s Pod<br/>Running on worker<br/>BGP route advertisement]
            
            BMWorker --> BMRoute
            BMWorker -.hosts.-> FRRPod
        end
        
        subgraph "Top of Rack Switch"
            ToR[ToR Switch<br/>BGP-enabled<br/>Layer 2/3 switching]
            ToRBGP[BGP Configuration<br/>Peers with FRR-K8s<br/>Peers with Core Router]
            
            ToR --> ToRBGP
        end
        
        StdRoute --> ToR
        BMRoute --> ToR
        FRRPod -.BGP Session.-> ToRBGP
        
        subgraph "Core Network"
            Core[Core Router<br/>Route aggregation<br/>Upstream connectivity]
            
            ToRBGP -.eBGP.-> Core
        end
        
        Core --> Internet((Internet))
    end
    
    subgraph "BGP Peering Topology"
        subgraph "Hub Cluster"
            HubToR[Hub ToR Switch<br/>ASN: 64512]
            HubFRR[FRR-K8s Pods<br/>ASN: 64514]
            
            HubFRR -.eBGP.-> HubToR
        end
        
        subgraph "Managed Cluster"
            MgdToR[Managed ToR Switch<br/>ASN: 64513]
            MgdFRR[FRR-K8s Pods<br/>ASN: 64515]
            
            MgdFRR -.eBGP.-> MgdToR
        end
        
        subgraph "Core"
            CoreRouter[Core Router<br/>Aggregates all routes]
        end
        
        HubToR -.eBGP.-> CoreRouter
        MgdToR -.eBGP.-> CoreRouter
        HubToR -.eBGP.-> MgdToR
    end
    
    style BMWorker fill:#f96,stroke:#333,stroke-width:2px
    style ToR fill:#9cf,stroke:#333,stroke-width:3px
    style Core fill:#9cf,stroke:#333,stroke-width:3px
```

## VM Networking Architecture

```mermaid
graph TB
    subgraph "OpenShift Virtualization Networking"
        subgraph "Bare Metal Nodes"
            Node1[Node 1<br/>worker-cnv label]
            Node2[Node 2<br/>worker-cnv label]
        end
        
        subgraph "Network Configuration"
            NNCP[NodeNetworkConfigurationPolicy<br/>nmstate operator]
            Bridge[Linux Bridge<br/>VLAN-aware]
            
            NNCP -.creates.-> Bridge
        end
        
        subgraph "Kubernetes Networking"
            CUDN[ClusterUserDefinedNetwork<br/>Layer 2 topology<br/>Persistent IPAM]
            NAD[NetworkAttachmentDefinition<br/>Secondary network]
            
            CUDN --> NAD
        end
        
        subgraph "Virtual Machines"
            VM1[VM: test-vm-1<br/>IP: 192.168.100.10]
            VM2[VM: test-vm-2<br/>IP: 192.168.100.11]
            
            VM1 -.attached.-> NAD
            VM2 -.attached.-> NAD
        end
        
        NAD --> Bridge
        Bridge --> Node1
        Bridge --> Node2
        
        subgraph "BGP Route Advertisement"
            FRRPod[FRR-K8s Pod<br/>Monitors pod/service IPs]
            VRF[VRF: vrf-cudn<br/>Table: 1572]
            Announce[Announces 192.168.100.0/24<br/>to ToR switch via BGP]
            
            FRRPod --> VRF
            VRF --> Announce
        end
        
        VM1 -.routes via.-> Announce
        VM2 -.routes via.-> Announce
    end
    
    subgraph "Network Infrastructure"
        ToR[ToR Switch<br/>Receives BGP advertisements<br/>Routes VM traffic to nodes]
        CoreRouter[Core Router<br/>Aggregates VM routes<br/>Distributes to other ToRs]
        
        Announce -.BGP Session.-> ToR
        ToR -.BGP Session.-> CoreRouter
    end
    
    style VM1 fill:#9f9,stroke:#333,stroke-width:2px
    style VM2 fill:#9f9,stroke:#333,stroke-width:2px
    style CUDN fill:#fc9,stroke:#333,stroke-width:2px
    style Bridge fill:#9cf,stroke:#333,stroke-width:2px
```

## GitOps VM Migration Flow

```mermaid
sequenceDiagram
    participant Operator as Platform Operator
    participant Git as HA Git Server<br/>(Active/Active)
    participant VirtSync as Virt-Git-Sync Operator
    participant Hub as Hub Cluster
    participant Mgd as Managed Cluster
    participant BGP as ToR Switches
    
    Note over Operator,BGP: Initial State: VM running on Managed Cluster
    
    Operator->>Git: Push updated VM manifest<br/>(change namespace to hub-vms)
    Git->>VirtSync: Webhook: repository updated
    VirtSync->>Git: Fetch latest manifests
    VirtSync->>VirtSync: Detect VM location change
    
    Note over VirtSync,Mgd: Migration Phase 1: Shutdown on Source
    
    VirtSync->>Mgd: Stop VM on managed cluster
    Mgd->>Mgd: VM graceful shutdown
    Mgd->>BGP: Release IP from IPAM
    BGP->>BGP: Withdraw route 192.168.100.x
    
    Note over VirtSync,Hub: Migration Phase 2: Startup on Target
    
    VirtSync->>Hub: Create VM on hub cluster
    Hub->>Hub: VM starts with same IP
    Hub->>BGP: Claim IP in IPAM
    BGP->>BGP: Advertise route 192.168.100.x
    
    Note over BGP: BGP Convergence<br/>Route update propagates
    
    BGP-->>Hub: Traffic now routes to hub cluster
    Hub-->>Operator: VM accessible at same IP<br/>(new physical location)
    
    Note over Operator,BGP: Final State: VM running on Hub Cluster<br/>Same IP, different physical location
```

## Storage Architecture

```mermaid
graph TB
    subgraph "OpenShift Data Foundation (Ceph)"
        subgraph "Storage Services"
            RBD[Block Storage<br/>Ceph RBD<br/>RWO volumes]
            CephFS[File Storage<br/>CephFS<br/>RWX volumes]
            RGW[Object Storage<br/>NooBaa/RGW<br/>S3-compatible]
        end
        
        subgraph "Ceph Components"
            MON[Ceph Monitors<br/>Cluster state<br/>3 replicas]
            MGR[Ceph Managers<br/>Management daemons<br/>2 replicas]
            OSD[Ceph OSDs<br/>Object Storage Daemons<br/>On bare metal nodes]
            MDS[CephFS Metadata<br/>File system metadata<br/>2 replicas]
        end
        
        MON --> OSD
        MGR --> OSD
        MDS --> OSD
        RGW --> OSD
        
        RBD --> MON
        CephFS --> MDS
    end
    
    subgraph "Storage Consumers"
        VMDisks[VM Disks<br/>DataVolumes<br/>KubeVirt VMs]
        Registry[Image Registry<br/>Container images]
        PVCs[Application PVCs<br/>Stateful workloads]
        
        VMDisks --> RBD
        Registry --> CephFS
        PVCs --> RBD
        PVCs --> CephFS
    end
    
    subgraph "Storage Classes"
        SC_RBD[StorageClass: ceph-rbd<br/>Block, RWO]
        SC_FS[StorageClass: cephfs<br/>File, RWX]
        SC_OBJ[StorageClass: noobaa<br/>Object, S3]
        
        SC_RBD --> RBD
        SC_FS --> CephFS
        SC_OBJ --> RGW
    end
    
    style OSD fill:#f96,stroke:#333,stroke-width:2px
    style VMDisks fill:#9f9,stroke:#333,stroke-width:2px
```

## Multi-Cluster Management (ACM)

```mermaid
graph TB
    subgraph "Hub Cluster - Management Plane"
        subgraph "ACM Components"
            MCH[MultiClusterHub<br/>Central management]
            Console[Web Console<br/>Multi-cluster view]
            Observability[Observability<br/>Metrics aggregation]
        end
        
        subgraph "Management Functions"
            ClusterMgmt[Cluster Lifecycle<br/>Import & provisioning]
            PolicyEngine[Policy Framework<br/>Governance & compliance]
            AppDeploy[Application Lifecycle<br/>Multi-cluster deployment]
        end
        
        MCH --> Console
        MCH --> Observability
        MCH --> ClusterMgmt
        MCH --> PolicyEngine
        MCH --> AppDeploy
    end
    
    subgraph "Managed Cluster - Data Plane"
        subgraph "ACM Agents"
            Klusterlet[Klusterlet<br/>Cluster registration]
            WorkAgent[Work Agent<br/>Manifest application]
            AddOns[Add-on Agents<br/>Observability, Policy]
        end
        
        subgraph "Deployed Operators"
            CNV[OpenShift Virtualization<br/>KubeVirt]
            ODF[OpenShift Data Foundation<br/>Storage]
            VirtSync[Virt-Git-Sync<br/>VM migration]
        end
        
        Klusterlet --> WorkAgent
        WorkAgent --> AddOns
        AddOns -.manages.-> CNV
        AddOns -.manages.-> ODF
    end
    
    ClusterMgmt -.registers.-> Klusterlet
    PolicyEngine -.enforces.-> AddOns
    AppDeploy -.deploys.-> WorkAgent
    Observability -.collects from.-> AddOns
    
    subgraph "GitOps Integration"
        GitServer[HA Git Server<br/>Active/Active<br/>Source of truth]
        ArgoCD[GitOps Controller<br/>Continuous sync]
        
        ArgoCD --> GitServer
        ArgoCD -.syncs to.-> WorkAgent
        VirtSync -.watches.-> GitServer
    end
    
    style MCH fill:#f9f,stroke:#333,stroke-width:3px
    style Klusterlet fill:#9ff,stroke:#333,stroke-width:2px
    style CNV fill:#9f9,stroke:#333,stroke-width:2px
```

## Key Technologies

### Networking
- **BGP (Border Gateway Protocol)**: Dynamic routing between clusters and routers
- **FRRouting**: Open-source routing software on router instances
- **FRR-K8s**: Kubernetes-native FRR integration for route advertisement
- **CUDN (ClusterUserDefinedNetwork)**: OVN-Kubernetes secondary network feature
- **nmstate**: Declarative network configuration on nodes

### Virtualization
- **OpenShift Virtualization**: KubeVirt-based VM management on Kubernetes
- **DataVolumes**: Persistent storage for VM disks
- **NetworkAttachmentDefinition**: Secondary network attachment for VMs

### Storage
- **Ceph**: Distributed storage system (block, file, object)
- **Rook Operator**: Kubernetes operator for Ceph
- **ODF (OpenShift Data Foundation)**: Enterprise storage platform

### Management
- **Red Hat ACM**: Multi-cluster lifecycle and governance
- **OpenShift GitOps**: ArgoCD-based continuous delivery
- **HA Git Server**: Active/Active Git repository (e.g., Gitea, GitLab, GitHub Enterprise)
- **Virt-Git-Sync**: Custom operator for Git-driven VM migration

## Network Flow Summary

1. **Standard Worker Traffic**: Workers → ToR Switch → Core Router → Internet
2. **Bare Metal Worker Traffic**: Workers → ToR Switch → Core Router → Internet
3. **VM Traffic**: VMs → Linux Bridge → FRR-K8s BGP Advertisement → ToR Switch → Core Router
4. **Shared VM Network Routing (192.168.100.0/24)**: 
   - **Hub cluster** advertises 192.168.100.0/24 → Hub ToR → Core Router
   - **Managed cluster** advertises 192.168.100.0/24 → Managed ToR → Core Router
   - Core Router learns **same prefix from both** clusters
   - **Automatic failover**: If one cluster fails, Core Router switches to remaining path
   - **Zero downtime**: BGP convergence redirects traffic without packet loss
5. **BGP Peering Topology**:
   - FRR-K8s on bare metal nodes ↔ ToR Switch (eBGP)
   - Hub ToR ↔ Core Router (eBGP via GRE tunnel)
   - Managed ToR ↔ Core Router (eBGP via GRE tunnel)
   - Core Router selects best path based on BGP attributes
6. **Management Access**: Operator → Bastion → Core Network → Clusters

## Architecture Abstractions

This logical architecture abstracts away cloud provider-specific implementations:

### AWS Implementation → Logical Equivalent

**Current Production Architecture (2026+):**
- **EC2 c5.metal instances** → Bare metal workers with nested virtualization
- **VPC Route Server** → ToR switch with native AWS BGP routing
- **Transit Gateway** → Core router providing cross-VPC routing
- **Transit Gateway Connect** → GRE tunnels for BGP peering between Core and ToR
- **Route Server BGP sessions** → Direct BGP peering from workers to ToR
- **Dynamic route propagation** → Automatic VPC route table updates
- **AWS NAT Gateway** → Internet egress for nodes
- **Security Groups** → Standard firewall rules (not shown in logical diagrams)

**Legacy Architecture (Optional, backwards compatibility):**
- **EC2 router with dual ENIs + NAT** → ToR switch with BGP capabilities (EC2-based)
- **VPC route table overrides** → Static routes pointing to EC2 router
- **VPC Peering** → Superseded by Transit Gateway

### On-Premises Implementation
This architecture maps directly to traditional data center deployments:
- **Bare metal servers** in racks with CNV workloads
- **ToR switches** (e.g., Cisco Nexus, Arista, Juniper) with BGP support
- **Core router** providing upstream connectivity and inter-rack routing
- **FRR-K8s** running on OpenShift nodes advertising VM routes
- **VLAN segmentation** for network isolation (10.0.0.0/16, 10.1.0.0/16, 192.168.100.0/24)

### Key Benefits of This Approach
1. **Cloud-agnostic**: Same architecture works on AWS, bare metal, or other cloud providers
2. **Standard protocols**: Uses BGP (industry standard) for dynamic routing
3. **No vendor lock-in**: FRRouting is open source, runs anywhere
4. **Scalable**: ToR/Core architecture supports growth (add more racks/clusters)
5. **Portable VMs**: Same IP address as VMs move between clusters (BGP handles routing updates)
6. **Automatic Failover**: Both clusters advertise same CUDN prefix; Core Router provides instant failover
7. **Zero Downtime**: BGP convergence time (<10 seconds) ensures minimal service interruption
8. **Active-Active or Active-Passive**: Flexible deployment based on BGP path selection policies

### HA Git Server Deployment
The architecture shows an **active/active HA Git server** deployment across both clusters:
- **Hub cluster**: Hosts one active instance of the Git server
- **Managed cluster**: Hosts another active instance
- **Shared database**: PostgreSQL with replication for consistency
- **Shared storage**: CephFS (RWX) or object storage for Git repositories
- **Load balanced**: External load balancer or multi-cluster ingress distributes requests
- **GitOps integration**: ArgoCD syncs from hub instance, Virt-Git-Sync watches managed instance
- **Fault tolerance**: If one cluster fails, Git server remains available via the other cluster

**Implementation options**: Gitea, GitLab, GitHub Enterprise, Bitbucket, or any Git server supporting HA deployment
