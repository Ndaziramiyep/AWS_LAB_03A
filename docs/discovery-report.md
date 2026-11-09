# Discovery Report: Onward Logistics Sales Day Demand

> Draft for Stage 1. Copy it into the official Discovery Report Template and share the link.

## Part A: What we found

### 1. The problem
Order traffic on Onward Logistics sales days runs at about **3× a normal day**, and nobody can predict exactly when.
The current fixed set of servers leaves two bad choices: size for the peak and pay for idle capacity all month,
or size for a normal day and slow down or fail when the rush arrives.

### 2. Common solutions
| Approach | How it works | Fit for Onward |
|---|---|---|
| Over-provision for peak | Run peak capacity all the time | Simple, but pays for about 3× capacity ~95% of the time |
| Manual scaling | Operators add servers when they see load | Slow, error-prone, needs someone on call. Breaks "without anyone touching it" |
| Scheduled scaling | Add capacity at fixed times | Only works when sale timing is known. Useful as an extra, not the base |
| Reactive auto scaling (target tracking / step) | Add or remove servers from a metric such as CPU | **Chosen.** Automatic in both directions, little to tune |
| Serverless (Lambda, Fargate) | The platform scales per request or task | Strong future option, but this engagement requires EC2 behind a load balancer |
| Managed PaaS (Elastic Beanstalk, App Runner) | Platform-managed fleet | Hides the networking and security controls the client wants to own |
| CDN or caching in front | Serve static content from the edge | Complements the design; does not help order writes |

### 3. What happens with no solution
- Slow pages and errors at the peak lose orders and merchants and damage customer trust.
- Engineers firefight at night to add servers by hand.
- Or the company pays every month for a fleet sized for the rush.
- One server or data centre (AZ) failure takes the order system down.

### 4. Security and resilience patterns
- Public load balancer in front of **private** compute, so servers have no public IPs.
- Security group chaining: only the ALB's security group can reach the app port.
- NAT for outbound-only internet (updates) without inbound exposure.
- Multi-AZ Auto Scaling Group with **load balancer health checks** that replaces failed servers.
- **SSM Session Manager** instead of SSH or bastions, so no admin ports are open.
- Secrets in Secrets Manager, least-privilege IAM through managed policies, IMDSv2.

### 5. Sources
- [EC2 Auto Scaling target tracking policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Elastic Load Balancing health checks for Auto Scaling](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-elb-health-checks.html)
- [Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html)
- [Regional NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html)
- [CloudFormation Git sync](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/git-sync.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- Well-Architected Framework: [Reliability](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html), [Security](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html), [Cost Optimization](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)

## Part B: Business value

### 1. Chosen approach
A single internet-facing Application Load Balancer is the only public entry point. Behind it, an EC2 Auto Scaling
Group of small instances runs in private subnets across two Availability Zones. A target tracking policy keeps
average CPU near 50%, adding servers during a sales rush and removing them afterwards. A Regional NAT Gateway lets
the servers download updates without being reachable. Everything is defined in one CloudFormation template that
deploys automatically from Git through Git sync, so the environment can be rebuilt from the repository at any time.

### 2. Services and why
| Service | Why |
|---|---|
| Amazon VPC (public and private subnets, 2 AZs) | Network isolation and AZ fault tolerance |
| Application Load Balancer | One stable public address, spreads requests, health checks |
| EC2 Auto Scaling and Launch Templates | Elastic, self-healing fleet. Every server is built the same way |
| Amazon CloudWatch | CPU metric and alarms that drive target tracking |
| Regional NAT Gateway | Outbound-only internet for all AZs from one resource |
| AWS Systems Manager | Admin access and remote commands with no open ports |
| AWS Secrets Manager | Holds the load-test token outside the code |
| AWS IAM (managed policies only) | Least privilege, auditable, no inline policies |
| CloudFormation and Git sync | Everything as code, deployed from Git, repeatable rebuild |

### 3. Who benefits
- **CTO**: capacity follows demand automatically, in both directions.
- **Head of Security**: one public entry point, private servers, no admin ports, secrets kept out of code.
- **Head of Ops**: survives a server or AZ loss, replaces servers automatically, shows which server answered.
- **Finance Lead**: pays for 2 small servers on quiet days and more only during the rush, with `MaxSize` capping the worst case.
- **Customers and merchants**: the order system stays fast and available on sales day.

### 4. Trade-offs and roadmap
- Orders are kept in memory on each server (demo scope). Next step: DynamoDB or RDS for shared, durable orders.
- HTTP only. Next step: an ACM certificate with HTTPS, AWS WAF, and CloudFront.
- Scale-in is deliberately slow (about 15 minutes) to avoid flapping.
- Later: containers (ECS on Fargate), Spot for burst capacity, a Savings Plan for the baseline.
