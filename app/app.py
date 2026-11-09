"""Onward Logistics order system: UI and order logic in one Flask app.

Each page shows who built it, which lab it is, and which server (instance ID
and Availability Zone) answered, so load balancing and failover are visible.
"""

import hmac                      # constant-time token comparison
import itertools                 # simple counter for order IDs
import os                        # environment variables, CPU count, nice()
import threading                 # locks shared by the request threads
import time                      # timing for the CPU burner
import urllib.request            # calls to the EC2 metadata service
from datetime import datetime, timezone       # UTC timestamps
from multiprocessing import Process           # one busy process per vCPU

from flask import Flask, abort, jsonify, render_template, request  # web framework

app = Flask(__name__)            # the WSGI app that gunicorn serves

STUDENT = os.getenv("STUDENT_NAME", "Student Name")    # full name shown on the page
LAB = os.getenv("LAB_NAME", "Handling Sales Day Demand for the Onward Logistics Order System")  # lab title
APP_VERSION = os.getenv("APP_VERSION", "local")        # Git ref this server was built from
MAX_BURN_SECONDS = 600           # hard cap on one load test (10 minutes)

ORDERS = []                      # in-memory orders, per instance (demo scope; DynamoDB/RDS in production)
_order_ids = itertools.count(1)  # next order ID on this instance
_orders_lock = threading.Lock()  # guards ORDERS across request threads


def imds(path):
    """Read one EC2 metadata value with IMDSv2; return 'local' when not on EC2."""
    try:
        tok_req = urllib.request.Request(                       # step 1: ask for a session token
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"},
        )
        token = urllib.request.urlopen(tok_req, timeout=2).read().decode()  # token valid 5 minutes
        req = urllib.request.Request(                           # step 2: read the value with the token
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
        )
        return urllib.request.urlopen(req, timeout=2).read().decode()       # e.g. i-0abc... or eu-west-1a
    except Exception:
        return "local"           # running on a laptop, not EC2


INSTANCE_ID = imds("instance-id")                 # which server answered
AZ = imds("placement/availability-zone")          # which AZ it lives in
PRIVATE_IP = imds("local-ipv4")                   # private address (proves no public IP is used)


def _load_token():
    """Fetch the /burn token from Secrets Manager (or LOAD_TOKEN when testing locally)."""
    if os.getenv("LOAD_TOKEN"):                    # local test shortcut, never set on EC2
        return os.environ["LOAD_TOKEN"]
    secret_id = os.getenv("TOKEN_SECRET_ID")       # secret ARN written by UserData
    if not secret_id:
        return None                                # no secret configured: /burn disabled
    import boto3                                   # imported lazily so local runs don't need AWS

    sm = boto3.client("secretsmanager", region_name=os.getenv("AWS_REGION"))  # uses the instance role
    return sm.get_secret_value(SecretId=secret_id)["SecretString"]            # the generated token


try:
    BURN_TOKEN = _load_token()                     # read once at startup
except Exception as exc:
    app.logger.warning("load token unavailable: %s", exc)
    BURN_TOKEN = None                              # fail closed: /burn returns 403

_burn_lock = threading.Lock()    # stops two requests starting a burn at the same moment
_burn_until = 0.0                # epoch time when the current burn ends


def _burn(seconds):
    """Spin one CPU at 100% for `seconds`, at the lowest priority."""
    if hasattr(os, "nice"):      # Linux only
        os.nice(19)              # lowest priority so /health still answers and the ALB keeps the instance
    end = time.time() + seconds  # when to stop
    while time.time() < end:     # tight loop = ~100% of one vCPU
        pass


def _start_burn(seconds):
    """Start one busy process per vCPU unless a burn is already running; return (started, seconds_left)."""
    global _burn_until
    with _burn_lock:
        now = time.time()
        if now < _burn_until:                          # already burning: ignore repeat clicks
            return False, int(_burn_until - now)
        for _ in range(os.cpu_count() or 2):           # one process per vCPU
            Process(target=_burn, args=(seconds,), daemon=True).start()
        _burn_until = now + seconds                    # remember when it ends
        return True, seconds


def _burning_for():
    """Seconds left on the current burn (0 when idle)."""
    return max(0, int(_burn_until - time.time()))


def _load_average():
    """1-minute load average, or None on systems without it (Windows)."""
    try:
        return round(os.getloadavg()[0], 2)
    except (AttributeError, OSError):
        return None


def _server_info():
    """Facts about the server that answered this request."""
    return {
        "instance_id": INSTANCE_ID,                    # EC2 instance ID
        "availability_zone": AZ,                       # AZ, proves multi-AZ spread
        "private_ip": PRIVATE_IP,                      # private IP only
        "load_1m": _load_average(),                    # current load
        "burning_seconds_left": _burning_for(),        # load-test status
        "version": APP_VERSION,                        # deployed Git ref
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),  # response time (UTC)
    }


@app.get("/")
def index():
    """Main page: student name, lab name, serving instance, order form, load simulator."""
    return render_template(
        "index.html",
        student=STUDENT,
        lab=LAB,
        server=_server_info(),
        burn_enabled=BURN_TOKEN is not None,           # hide the simulator if no token
    )


@app.get("/health")
def health():
    """ALB health check target: 200 means healthy."""
    return "ok", 200


@app.get("/whoami")
def whoami():
    """JSON identity of the answering server (used by curl loops and the page)."""
    return jsonify(_server_info())


@app.post("/orders")
def create_order():
    """Validate and store an order on this instance; return it with 201."""
    data = request.get_json(silent=True) or {}         # empty dict on bad JSON
    item = str(data.get("item") or "").strip()[:80]    # item name, max 80 chars
    try:
        qty = int(data.get("qty", 1))                  # quantity must be a number
    except (TypeError, ValueError):
        qty = 0                                        # forces the validation error below
    if not item or not 1 <= qty <= 1000:               # reject empty item or silly quantity
        return jsonify(error="item is required and qty must be 1-1000"), 400
    with _orders_lock:
        order = {
            "id": next(_order_ids),                    # unique per instance
            "item": item,
            "qty": qty,
            "status": "received",
            "handled_by": INSTANCE_ID,                 # shows which server took the order
            "availability_zone": AZ,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        ORDERS.append(order)                           # save in memory
    return jsonify(order), 201


@app.get("/orders")
def list_orders():
    """List the orders held by the answering instance."""
    with _orders_lock:
        orders = list(ORDERS)                          # copy under the lock
    return jsonify(orders=orders, count=len(orders), served_by=INSTANCE_ID, availability_zone=AZ)


@app.post("/burn")
def burn_cpu():
    """Token-protected load generator that pushes this server's CPU to 100% to trigger scale-out."""
    supplied = request.headers.get("X-Load-Token", "")                      # token from the page
    if not BURN_TOKEN or not hmac.compare_digest(supplied.encode(), BURN_TOKEN.encode()):
        abort(403)                                     # wrong or missing token
    try:
        secs = int(request.args.get("seconds", 300))   # requested duration
    except ValueError:
        secs = 300                                     # default 5 minutes
    secs = max(10, min(secs, MAX_BURN_SECONDS))        # clamp to 10..600 s
    started, remaining = _start_burn(secs)
    return jsonify(
        status="started" if started else "already-burning",
        seconds=remaining,
        instance_id=INSTANCE_ID,
        availability_zone=AZ,
    )


if __name__ == "__main__":                             # local run only; EC2 uses gunicorn
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), threaded=True)
