# Architecture Diagrams

## Overall Infrastructure Architecture

```mermaid
graph TB
    subgraph "AWS Region: us-east-1"
        subgraph "Bastion VPC (10.255.0.0/16)"
            Bastion[Bastion EC2<br/>10.255.1.x<br/>Public IP: 44.201.38.246]
            BastionIGW[Internet Gateway]
            Bastion --> BastionIGW
        end
        
        subgraph "Hub Cluster VPC (10.0.0.0/16)"
            subgraph "Public Subnets"
                HubPubA[10.0.1.0/24<br/>us-east-1a]
                HubPubB[10.0.2.0/24<br/>us-east-1b]
                HubPubC[10.0.3.0/24<br/>us-east-1c]
            end
            
            subgraph "Private Subnets"
                HubPrivA[10.0.11.0/24<br/>us-east-1a]
                HubPrivB[10.0.12.0/24<br/>us-east-1b]
                HubPrivC[10.0.13.0/24<br/>us-east-1c]
            end
            
            HubRouter[FRR Router<br/>10.0.11.111<br/>Amazon Linux 2023]
            HubNAT[NAT Gateway]
            HubIGW[Internet Gateway]
            
            subgraph "Hub OpenShift Cluster"
                HubMasters[Control Plane<br/>3x m5.xlarge]
                HubWorkers[Workers<br/>3x m5.2xlarge]
                HubBareMetal[Bare Metal<br/>c5.metal<br/>worker-cnv]
            end
            
            HubRouter -.BGP.-> HubBareMetal
            HubBareMetal --> HubPrivA
            HubMasters --> HubPrivA & HubPrivB & HubPrivC
            HubWorkers --> HubPrivA & HubPrivB & HubPrivC
            HubPrivA & HubPrivB & HubPrivC --> HubNAT
            HubNAT --> HubPubA
            HubPubA --> HubIGW
            HubIGW --> Internet((Internet))
        end
       
        subgraph "Managed Cluster VPC (10.1.0.0/16)"
            subgraph "Public Subnets"
                MgdPubA[10.1.1.0/24<br/>us-east-1a]
                MgdPubB[10.1.2.0/24<br/>us-east-1b]
                MgdPubC[10.1.3.0/24<br/>us-east-1c]
            end
            
            subgraph "Private Subnets"
                MgdPrivA[10.1.11.0/24<br/>us-east-1a]
                MgdPrivB[10.1.12.0/24<br/>us-east-1b]
                MgdPrivC[10.1.13.0/24<br/>us-east-1c]
            end
            
            MgdRouter[FRR Router<br/>10.1.11.224<br/>Amazon Linux 2023]
            MgdNAT[NAT Gateway]
            MgdIGW[Internet Gateway]
            
            subgraph "Managed OpenShift Cluster"
                MgdMasters[Control Plane<br/>3x m5.xlarge]
                MgdWorkers[Workers<br/>3x m5.2xlarge]
                MgdBareMetal[Bare Metal<br/>c5.metal<br/>worker-cnv]
            end
            
            MgdRouter -.BGP.-> MgdBareMetal
            MgdBareMetal --> MgdPrivA
            MgdMasters --> MgdPrivA & MgdPrivB & MgdPrivC
            MgdWorkers --> MgdPrivA & MgdPrivB & MgdPrivC
            MgdPrivA & MgdPrivB & MgdPrivC --> MgdNAT
            MgdNAT --> MgdPubA
            MgdPubA --> MgdIGW
            MgdIGW --> Internet((Internet))
        end
       
        Bastion <-.VPC Peering.-> HubMasters
        Bastion <-.VPC Peering.-> MgdMasters
        HubMasters <-.VPC Peering.-> MgdMasters
        
    end
     
    User[User/Operator]
    User --> Bastion
    
    style HubBareMetal fill:#f96,stroke:#333,stroke-width:3px
    style MgdBareMetal fill:#f96,stroke:#333,stroke-width:3px
    style HubRouter fill:#9cf,stroke:#333,stroke-width:2px
    style MgdRouter fill:#9cf,stroke:#333,stroke-width:2px
```

## Bare Metal BGP Routing Architecture

```mermaid
graph TB
    subgraph "Hub Cluster - Bare Metal Node Routing"
        subgraph "c5.metal Node (10.0.11.x)"
            BM1[Bare Metal Node<br/>Role: worker-cnv]
            BM1Intf[Primary Interface<br/>ens5]
            BM1GW[Default Gateway<br/>→ 10.0.11.111]
            BM1MC[MachineConfig<br/>98-worker-cnv-bgp-gateway]
            
            BM1MC -.applies to.-> BM1
            BM1 --> BM1Intf
            BM1Intf --> BM1GW
        end
        
        subgraph "FRR Router (10.0.11.111)"
            Router1[EC2 t3.small<br/>Amazon Linux 2023]
            Router1FRR[FRRouting Daemon<br/>BGP + OSPF]
            Router1Fwd[IP Forwarding<br/>Enabled]
            
            Router1 --> Router1FRR
            Router1 --> Router1Fwd
        end
        
        BM1GW --> Router1
        Router1 --> NATGateway[NAT Gateway<br/>10.0.1.x]
        NATGateway --> Internet1((Internet))
        
        subgraph "MachineConfig Details"
            Script[/usr/local/bin/set-gw.sh<br/>NetworkManager Script]
            Service[systemd-bgp-gw.service<br/>Runs on Boot]
            
            Script -.executed by.-> Service
            Service -.configured by.-> BM1MC
        end
    end
    
    subgraph "NetworkManager Configuration Process"
        DetectIntf[Detect Primary Interface<br/>ip route show default]
        GetConn[Get NM Connection<br/>nmcli con show]
        ModifyGW[Modify Gateway<br/>nmcli con modify]
        ApplyConfig[Bring Connection Up<br/>nmcli con up]
        
        DetectIntf --> GetConn
        GetConn --> ModifyGW
        ModifyGW --> ApplyConfig
    end
    
    style BM1 fill:#f96,stroke:#333,stroke-width:3px
    style Router1 fill:#9cf,stroke:#333,stroke-width:2px
    style BM1MC fill:#ff9,stroke:#333,stroke-width:2px
```

## VM Network (CUDN) Architecture

```mermaid
graph TB
    subgraph "Hub Cluster - VM Networking"
        subgraph "Bare Metal Nodes"
            BM1[Bare Metal Node 1<br/>worker-cnv]
            BM2[Bare Metal Node 2<br/>worker-cnv]
        end
        
        subgraph "OpenShift Virtualization"
            CNV[OpenShift Virtualization<br/>KubeVirt Operator]
            
            subgraph "NetworkAttachmentDefinition"
                NAD[vm-network<br/>Type: bridge<br/>VLAN: 100]
            end
            
            subgraph "Virtual Machines"
                VM1[VM: test-vm-1<br/>192.168.100.10/24]
                VM2[VM: test-vm-2<br/>192.168.100.11/24]
            end
        end
        
        subgraph "Network Configuration"
            NNCP[NodeNetworkConfigurationPolicy<br/>Creates bridge0]
            Bridge[Linux Bridge: bridge0<br/>VLAN 100]
            
            NNCP -.creates.-> Bridge
            Bridge --> BM1
            Bridge --> BM2
        end
        
        CNV --> VM1
        CNV --> VM2
        VM1 -.attached to.-> NAD
        VM2 -.attached to.-> NAD
        NAD --> Bridge
        
        Router[FRR Router<br/>10.0.11.111]
        Bridge -.BGP Routes.-> Router
        
        subgraph "CUDN Routes (192.168.100.0/24)"
            Route1[Advertisement via BGP]
            Route2[VRF: vrf-cudn]
            Route3[Table ID: 1572]
            
            Route1 --> Route2
            Route2 --> Route3
        end
    end
    
    subgraph "Managed Cluster - VM Networking"
        BM3[Bare Metal Nodes<br/>worker-cnv]
        CNV2[OpenShift Virtualization]
        NAD2[vm-network<br/>VLAN 100]
        VM3[VMs<br/>192.168.100.x]
        Router2[FRR Router<br/>10.1.11.224]
        
        CNV2 --> VM3
        VM3 --> NAD2
        NAD2 --> BM3
        BM3 -.BGP Routes.-> Router2
    end
    
    Router <-.BGP Peering.-> Router2
    
    style VM1 fill:#9f9,stroke:#333,stroke-width:2px
    style VM2 fill:#9f9,stroke:#333,stroke-width:2px
    style VM3 fill:#9f9,stroke:#333,stroke-width:2px
    style NAD fill:#fc9,stroke:#333,stroke-width:2px
    style NAD2 fill:#fc9,stroke:#333,stroke-width:2px
```

## ACM Hub and Spoke Architecture

```mermaid
graph TB
    subgraph "Hub Cluster"
        subgraph "ACM Components"
            MCH[MultiClusterHub<br/>ACM Operator]
            Console[ACM Console]
            Observability[Observability<br/>Metrics & Alerts]
            
            MCH --> Console
            MCH --> Observability
        end
        
        subgraph "Cluster Management"
            Import[Cluster Import<br/>auto-import-secret]
            Policy[Policy Framework<br/>Governance]
            App[Application Lifecycle]
            
            MCH --> Import
            MCH --> Policy
            MCH --> App
        end
        
        subgraph "GitOps"
            Gitea[Gitea Server<br/>Git Repository]
            ArgoCD[OpenShift GitOps<br/>ArgoCD]
            
            ArgoCD --> Gitea
        end
    end
    
    subgraph "Managed Cluster"
        subgraph "Managed Components"
            Klusterlet[Klusterlet Agent]
            WorkAgent[Work Agent]
            Addon[Add-on Agents]
        end
        
        subgraph "Deployed Workloads"
            CNV[OpenShift Virtualization]
            ODF[OpenShift Data Foundation]
            VirtSync[Virt-Git-Sync Operator]
        end
        
        Klusterlet --> WorkAgent
        WorkAgent --> Addon
        Addon -.manages.-> CNV
        Addon -.manages.-> ODF
        Policy -.deploys.-> VirtSync
    end
    
    Import -.registers.-> Klusterlet
    Policy -.enforces policies.-> Addon
    App -.deploys apps.-> Addon
    Observability -.collects metrics.-> Klusterlet
    ArgoCD -.syncs manifests.-> Addon
    
    style MCH fill:#f9f,stroke:#333,stroke-width:3px
    style Klusterlet fill:#9ff,stroke:#333,stroke-width:2px
    style CNV fill:#9f9,stroke:#333,stroke-width:2px
```

## Data Flow: VM Live Migration Simulation

```mermaid
sequenceDiagram
    participant User
    participant Gitea as Gitea Repository
    participant VirtSync as Virt-Git-Sync Operator
    participant K8s as Kubernetes API
    participant VM as Virtual Machine
    participant Hub as Hub Router (BGP)
    participant Mgd as Managed Router (BGP)
    
    User->>Gitea: Push VM manifest update<br/>(namespace: test-migration)
    Gitea->>VirtSync: Webhook notification
    VirtSync->>Gitea: Fetch updated manifest
    VirtSync->>K8s: Check existing VM state
    K8s-->>VirtSync: VM running on managed cluster
    
    VirtSync->>K8s: Apply updated manifest<br/>(triggers failover)
    K8s->>VM: Stop VM on managed cluster
    VM->>Mgd: Release IP 192.168.100.x
    Mgd->>Hub: Withdraw BGP route
    
    K8s->>VM: Start VM on hub cluster
    VM->>Hub: Claim IP 192.168.100.x
    Hub->>Mgd: Advertise BGP route
    
    Note over Hub,Mgd: BGP convergence<br/>Route update propagates
    
    Mgd-->>K8s: Traffic now routes to hub
    VM-->>User: VM accessible at new location<br/>(same IP address)
```

## Component Deployment Flow

```mermaid
graph LR
    subgraph "Phase 1: Prerequisites"
        P1[AWS Quota Check]
        P2[Credentials Validation]
        P3[Ansible Version Check]
    end
    
    subgraph "Phase 2: Infrastructure"
        I1[Create VPCs]
        I2[Create Subnets]
        I3[Configure Routing]
        I4[Deploy Bastion]
        I5[VPC Peering]
        
        I1 --> I2 --> I3 --> I4 --> I5
    end
    
    subgraph "Phase 3: OpenShift Install"
        O1[Generate install-config.yaml]
        O2[Start tmux sessions]
        O3[Deploy Control Plane]
        O4[Deploy Workers]
        O5[Configure OAuth]
        
        O1 --> O2 --> O3 --> O4 --> O5
    end
    
    subgraph "Phase 4: ACM Setup"
        A1[Install ACM Operator]
        A2[Create MultiClusterHub]
        A3[Import Managed Cluster]
        A4[Configure Observability]
        
        A1 --> A2 --> A3 --> A4
    end
    
    subgraph "Phase 5: Bare Metal"
        B1[Create MachineConfig<br/>BGP Gateway]
        B2[Deploy MachineSets<br/>c5.metal]
        B3[Nodes Boot with<br/>BGP Routing]
        
        B1 --> B2 --> B3
    end
    
    subgraph "Phase 6: Storage & Virtualization"
        S1[Deploy ODF Operator]
        S2[Create StorageSystem]
        S3[Deploy CNV Operator]
        S4[Create HyperConverged]
        S5[Configure VM Network]
        
        S1 --> S2 --> S3 --> S4 --> S5
    end
    
    subgraph "Phase 7: GitOps"
        G1[Deploy Gitea]
        G2[Deploy OpenShift GitOps]
        G3[Configure Repositories]
        G4[Deploy Virt-Git-Sync]
        
        G1 --> G2 --> G3 --> G4
    end
    
    P1 & P2 & P3 --> I1
    I5 --> O1
    O5 --> A1
    A4 --> B1
    B3 --> S1
    S5 --> G1
    
    style P1 fill:#e1f5ff
    style I1 fill:#fff5e1
    style O1 fill:#ffe1e1
    style A1 fill:#e1ffe1
    style B1 fill:#f5e1ff
    style S1 fill:#ffe1f5
    style G1 fill:#f5ffe1
```

## Security Groups and Firewall Rules

```mermaid
graph TB
    subgraph "Bastion Security Group"
        BSG[bastion-vpc-sg]
        BSG_SSH[SSH: 22<br/>Source: 0.0.0.0/0]
        BSG_Internal[All Traffic<br/>Source: 10.0.0.0/8]
        
        BSG --> BSG_SSH
        BSG --> BSG_Internal
    end
    
    subgraph "Hub Cluster Security Group"
        HSG[hub-cluster-vpc-cluster-sg]
        HSG_API[API: 6443<br/>Source: Bastion + Managed]
        HSG_Apps[Apps: 443, 80<br/>Source: 0.0.0.0/0]
        HSG_Internal[All Cluster Traffic<br/>Source: Hub VPC]
        HSG_BGP[BGP: 179<br/>Source: Router IP]
        
        HSG --> HSG_API
        HSG --> HSG_Apps
        HSG --> HSG_Internal
        HSG --> HSG_BGP
    end
    
    subgraph "Managed Cluster Security Group"
        MSG[managed-cluster-vpc-cluster-sg]
        MSG_API[API: 6443<br/>Source: Bastion + Hub]
        MSG_Apps[Apps: 443, 80<br/>Source: 0.0.0.0/0]
        MSG_Internal[All Cluster Traffic<br/>Source: Managed VPC]
        MSG_BGP[BGP: 179<br/>Source: Router IP]
        
        MSG --> MSG_API
        MSG --> MSG_Apps
        MSG --> MSG_Internal
        MSG --> MSG_BGP
    end
    
    subgraph "Router Security Groups"
        RSG_Hub[frr-router-hub-sg]
        RSG_Mgd[frr-router-managed-sg]
        
        RSG_Rules[SSH: 22<br/>BGP: 179<br/>All from VPC<br/>All from VM Network]
        
        RSG_Hub --> RSG_Rules
        RSG_Mgd --> RSG_Rules
    end
    
    BSG -.peering.-> HSG
    BSG -.peering.-> MSG
    HSG -.peering.-> MSG
    HSG --> RSG_Hub
    MSG --> RSG_Mgd
    
    style BSG fill:#e1f5ff,stroke:#333,stroke-width:2px
    style HSG fill:#ffe1e1,stroke:#333,stroke-width:2px
    style MSG fill:#e1ffe1,stroke:#333,stroke-width:2px
    style RSG_Hub fill:#f5e1ff,stroke:#333,stroke-width:2px
    style RSG_Mgd fill:#ffe1f5,stroke:#333,stroke-width:2px
```

## Storage Architecture (ODF)

```mermaid
graph TB
    subgraph "OpenShift Data Foundation"
        subgraph "Storage Classes"
            SC1[ocs-storagecluster-ceph-rbd<br/>Block Storage<br/>RWO]
            SC2[ocs-storagecluster-cephfs<br/>File Storage<br/>RWX]
            SC3[openshift-storage.noobaa.io<br/>Object Storage<br/>S3]
        end
        
        subgraph "Ceph Cluster"
            Mon[Ceph Monitors<br/>3 replicas]
            MGR[Ceph Managers<br/>2 replicas]
            OSD[Ceph OSDs<br/>On bare metal nodes<br/>gp3 EBS volumes]
            MDS[CephFS MDS<br/>2 replicas]
            RGW[Rados Gateway<br/>NooBaa]
            
            Mon --> OSD
            MGR --> OSD
            MDS --> OSD
            RGW --> OSD
        end
        
        subgraph "Storage System"
            SS[StorageSystem<br/>ocs-storagecluster]
            Device[DeviceSet<br/>Size: 512Gi<br/>Replicas: 1 per node]
            
            SS --> Device
            Device --> OSD
        end
        
        SC1 --> Mon
        SC2 --> MDS
        SC3 --> RGW
    end
    
    subgraph "Consumers"
        PVC1[PersistentVolumeClaims<br/>VMs, Apps, Registry]
        VM[Virtual Machine Disks<br/>DataVolumes]
        Registry[Image Registry<br/>Storage]
        
        PVC1 --> SC1
        VM --> SC1
        Registry --> SC2
    end
    
    style OSD fill:#f96,stroke:#333,stroke-width:2px
    style SC1 fill:#9cf,stroke:#333,stroke-width:2px
    style SC2 fill:#9cf,stroke:#333,stroke-width:2px
    style VM fill:#9f9,stroke:#333,stroke-width:2px
```
