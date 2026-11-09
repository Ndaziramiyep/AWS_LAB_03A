# Architecture

Paste the Mermaid block into draw.io (*Arrange → Insert → Advanced → Mermaid*) or [mermaid.live](https://mermaid.live),
then restyle it with official AWS icons and export it as `docs/architecture.png`.

```mermaid
flowchart TB
  U["Internet users / merchants"] -->|"1 - HTTP :80"| IGW["Internet Gateway"]
  subgraph VPC["VPC 10.0.0.0/16 (eu-west-1)"]
    subgraph PUB["PUBLIC subnets: 10.0.0.0/24 (AZ-a), 10.0.1.0/24 (AZ-b) | route 0.0.0.0/0 -> IGW"]
      ALB["Application Load Balancer<br/>ALB SG: inbound 80 from 0.0.0.0/0"]
      NAT["Regional NAT Gateway<br/>(one gateway, spans both AZs)"]
    end
    subgraph PRIVA["PRIVATE subnet AZ-a 10.0.10.0/24 | route 0.0.0.0/0 -> NAT"]
      A1["EC2 t3.micro (ASG)<br/>App SG: 8080 from ALB SG only<br/>no public IP, no port 22"]
    end
    subgraph PRIVB["PRIVATE subnet AZ-b 10.0.11.0/24 | route 0.0.0.0/0 -> NAT"]
      A2["EC2 t3.micro (ASG)<br/>App SG: 8080 from ALB SG only<br/>no public IP, no port 22"]
    end
    ALB -->|"2 - :8080 SG-to-SG, health check GET /health"| A1
    ALB -->|"2 - :8080 SG-to-SG"| A2
    A1 -->|"3 - outbound 80/443"| NAT
    A2 -->|"3 - outbound 80/443"| NAT
  end
  IGW --> ALB
  NAT -->|"3 - updates, git, pip, SSM"| IGW

  subgraph CP["Control plane"]
    ASG["Auto Scaling Group<br/>min 2 / max 6, ELB health checks"]
    CW["CloudWatch ASGAverageCPUUtilization<br/>target tracking 50%"]
    SSM["SSM Session Manager / Run Command"]
    SM["Secrets Manager<br/>load-test token"]
    GIT["GitHub repo"] -->|"CodeConnections"| GS["CloudFormation Git sync"] --> CFN["CloudFormation stack"]
  end
  CW -. "scale out / in" .-> ASG
  ASG -. "launch / replace" .-> A1
  ASG -. "launch / replace" .-> A2
  SSM -. "admin access over HTTPS, no inbound ports" .-> A1
  A1 -. "GetSecretValue" .-> SM
```

## Legend
| Number | Flow |
|---|---|
| 1 | User → Internet Gateway → ALB (the only public endpoint) |
| 2 | ALB → instance on port 8080. Allowed only because the App SG references the ALB SG |
| 3 | Instance → Regional NAT → IGW. Outbound only, for updates, `git clone`, `pip` and SSM |

## Diagram checklist
- [ ] VPC and CIDR, 2 Availability Zones
- [ ] Public subnets (ALB, Regional NAT) clearly labelled **public**
- [ ] Private subnets (EC2 in the ASG) clearly labelled **private**
- [ ] IGW and route tables (public to IGW, private to NAT)
- [ ] Security group rules on the arrows
- [ ] Numbered traffic flows
- [ ] Control plane: ASG, CloudWatch target tracking, SSM, Secrets Manager, Git → Git sync → CloudFormation
- [ ] Official AWS icons and a legend; export as PNG into `docs/`
