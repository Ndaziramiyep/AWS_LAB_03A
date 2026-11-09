# Cost Model: Quiet Day vs Sales Day

> Approximate **eu-west-1 (Ireland), on-demand** list prices. Before submitting, rebuild these figures in the
> [AWS Pricing Calculator](https://calculator.aws/) and attach the export link here.

## Assumptions
- Quiet day: the fleet sits at the minimum of 2 × `t3.micro`, one per AZ, for 24 h.
- Sales day: demand triples for about 6 h. Target tracking grows the fleet to as many as 6 instances, then shrinks it back to 2.
- One Regional NAT Gateway, active in 2 AZs (it is billed per AZ it runs in). Only updates and package downloads go through it.
- Internet-facing ALB, low LCU usage.

| Component | Unit price (approx.) | Quiet day | Sales day |
|---|---|---|---|
| EC2 `t3.micro` (Linux) | $0.0114 / instance-hour | 2 × 24 h = 48 h → **$0.55** | 48 h + 4 extra × 6 h = 72 h → **$0.82** |
| T3 unlimited surplus credits | $0.05 / vCPU-hour above baseline | $0 | ~4 instances × 2 vCPU × 6 h × ~40% → **~$1.00** worst case |
| Application Load Balancer | $0.0252 / hour + $0.008 / LCU-hour | 24 h → **$0.60** + ~$0.05 LCU | **$0.60** + ~$0.20 LCU |
| Regional NAT Gateway (hourly) | $0.048 / hour per active AZ | 2 AZ × 24 h → **$2.30** | **$2.30** |
| NAT data processing | $0.048 / GB | ~1 GB → **$0.05** | ~3 GB (scale-out bootstraps) → **$0.15** |
| EBS gp3 8 GB per instance | $0.088 / GB-month | 2 × 8 GB → **$0.05** | ~**$0.06** |
| Secrets Manager | $0.40 / secret-month | **$0.01** | **$0.01** |
| CloudWatch detailed monitoring | ~$2.10 / instance-month (7 metrics) | **$0.14** | **$0.20** |
| **Total per day** | | **≈ $3.75** | **≈ $5.35** |

Monthly baseline (30 quiet days): **≈ $112**, mostly the NAT Gateway and ALB. If a fixed fleet of 6 instances
ran all month instead of auto scaling, compute alone would rise from ~$16 to ~$49, about **3×**, for capacity
that sits idle about 95% of the time.

## Key messages for the Finance Lead
1. **Compute is the smallest line.** The fixed costs (NAT and ALB) dominate. A whole sales day adds about **$1.50**,
   most of it from extra instances that exist only while they are needed.
2. **Auto scaling vs a peak-sized fleet:** we pay for 2 instances on quiet days and up to 6 only during the rush.
   `MaxSize = 6` caps the worst-case compute bill.
3. **Regional NAT:** one gateway to manage for every AZ. You still pay per active AZ, but there is no per-AZ
   gateway, route table or failover wiring to look after.
4. **Burstable credits:** `t3` *unlimited* mode keeps the CPU at full speed during a spike, for a few cents of
   surplus credits. *Standard* mode avoids that charge but throttles the CPU, which can stop the scale-out signal.

## Ways to cut cost later
- A Compute Savings Plan for the always-on 2 instances (about 30% off the baseline compute).
- Spot instances for burst capacity above the baseline (in a mixed-instances ASG).
- VPC endpoints for SSM and Secrets Manager to cut NAT data. At this traffic level the endpoints' hourly fee costs more, so this only pays off at scale.
- An AWS Budget with an alert at the expected monthly figure.
