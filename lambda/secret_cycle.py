"""
secret_cycle.py – AWS Secrets Manager rotation Lambda handler.

Supports two rotation strategies:
  single  – rotates a single username/password pair in place.
  ab      – alternates between an "a" and "b" suffixed username so that
             the old credentials remain valid until the rotation is
             finished (soft handoff).

After a successful rotation the handler can optionally:
  * force a new ECS deployment so tasks pick up the refreshed secret.
  * trigger a Kubernetes rollout-restart so pods reload the secret.

Configuration is provided entirely through environment variables so that
the same package works both as a Lambda function (triggered by Secrets
Manager) and as a stand-alone container/pod (e.g. via a Helm chart
CronJob).

Environment Variables
---------------------
ROTATION_TYPE           "single" | "ab"  (default: "ab")
DB_ENGINE               "postgres" | "mysql" | "mariadb"  (default: "postgres")
MASTER_SECRET_ARN       ARN of the master credentials secret used to
                        perform DDL (CREATE / ALTER USER).  Required for
                        the "ab" strategy and for managed DB engines.
PASSWORD_LENGTH         Length of generated passwords  (default: 32)
EXCLUDE_CHARACTERS      Characters to exclude from passwords
                        (default: '/@"\'\\')

ECS_CLUSTER             ECS cluster name – if set, force a new deployment
ECS_SERVICE             ECS service name – required when ECS_CLUSTER is set

K8S_NAMESPACE           Kubernetes namespace – if set, trigger rollout restart
K8S_DEPLOYMENT          Kubernetes deployment name – required with K8S_NAMESPACE
K8S_IN_CLUSTER          "true" | "false" – use in-cluster SA credentials
                        (default: "true")
KUBECONFIG_SECRET_ARN   ARN of a Secrets Manager secret that contains the
                        kubeconfig YAML (used when K8S_IN_CLUSTER=false)
"""

import json
import logging
import os
import secrets
import string
from datetime import datetime, timezone

import boto3
import psycopg2
import pymysql

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Constants / defaults
# ---------------------------------------------------------------------------
_DEFAULT_PASSWORD_LENGTH = 32
_DEFAULT_EXCLUDE_CHARS = "/@\"'\\"
_PENDING_SUFFIX = "AWSPENDING"
_CURRENT_SUFFIX = "AWSCURRENT"
_PREVIOUS_SUFFIX = "AWSPREVIOUS"

_AB_SUFFIXES = ("_a", "_b")


# ---------------------------------------------------------------------------
# Lambda entry-point
# ---------------------------------------------------------------------------

def lambda_handler(event, context):  # noqa: D401 – standard Lambda signature
    """Entry-point called by AWS Secrets Manager during rotation."""
    secret_arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    client = _secrets_client()

    # Validate that rotation is enabled and the token is valid.
    metadata = client.describe_secret(SecretId=secret_arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"Secret {secret_arn} does not have rotation enabled")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"Token {token} is not associated with secret {secret_arn}")

    if _CURRENT_SUFFIX in versions.get(token, []):
        logger.info("Token %s is already the AWSCURRENT version – nothing to do", token)
        return

    if _PENDING_SUFFIX not in versions.get(token, []):
        raise ValueError(
            f"Token {token} is not in AWSPENDING state for secret {secret_arn}"
        )

    rotation_type = os.environ.get("ROTATION_TYPE", "ab").lower()
    handler = _AbRotationHandler(client) if rotation_type == "ab" else _SingleRotationHandler(client)

    dispatch = {
        "createSecret": handler.create_secret,
        "setSecret": handler.set_secret,
        "testSecret": handler.test_secret,
        "finishSecret": handler.finish_secret,
    }

    if step not in dispatch:
        raise ValueError(f"Unknown rotation step: {step}")

    dispatch[step](secret_arn, token)


# ---------------------------------------------------------------------------
# Rotation handlers
# ---------------------------------------------------------------------------

class _BaseRotationHandler:
    """Shared helpers used by both rotation strategies."""

    def __init__(self, client):
        self._client = client

    # ------------------------------------------------------------------
    # Secret I/O helpers
    # ------------------------------------------------------------------

    def _get_secret_value(self, secret_arn, stage):
        kwargs = {"SecretId": secret_arn, "VersionStage": stage}
        return json.loads(self._client.get_secret_value(**kwargs)["SecretString"])

    def _put_secret_value(self, secret_arn, token, secret_dict):
        self._client.put_secret_value(
            SecretId=secret_arn,
            ClientRequestToken=token,
            SecretString=json.dumps(secret_dict),
            VersionStages=[_PENDING_SUFFIX],
        )

    # ------------------------------------------------------------------
    # Password generation
    # ------------------------------------------------------------------

    @staticmethod
    def _generate_password():
        length = int(os.environ.get("PASSWORD_LENGTH", _DEFAULT_PASSWORD_LENGTH))
        exclude = set(os.environ.get("EXCLUDE_CHARACTERS", _DEFAULT_EXCLUDE_CHARS))
        alphabet = "".join(
            c for c in (string.ascii_letters + string.digits + string.punctuation)
            if c not in exclude
        )
        # Guarantee at least one of each required class.
        required = [
            secrets.choice(string.ascii_uppercase),
            secrets.choice(string.ascii_lowercase),
            secrets.choice(string.digits),
        ]
        rest = [secrets.choice(alphabet) for _ in range(length - len(required))]
        combined = required + rest
        secrets.SystemRandom().shuffle(combined)
        return "".join(combined)

    # ------------------------------------------------------------------
    # Database helpers
    # ------------------------------------------------------------------

    def _get_connection(self, secret_dict):
        engine = os.environ.get("DB_ENGINE", secret_dict.get("engine", "postgres")).lower()
        host = secret_dict["host"]
        port = int(secret_dict.get("port", 5432 if engine == "postgres" else 3306))
        dbname = secret_dict.get("dbname", secret_dict.get("database", ""))
        username = secret_dict["username"]
        password = secret_dict["password"]

        if engine == "postgres":
            return psycopg2.connect(
                host=host,
                port=port,
                dbname=dbname,
                user=username,
                password=password,
                connect_timeout=5,
                sslmode="require",
            )
        if engine in ("mysql", "mariadb"):
            return pymysql.connect(
                host=host,
                port=port,
                database=dbname,
                user=username,
                password=password,
                connect_timeout=5,
                ssl={"ssl": {}},
            )
        raise ValueError(f"Unsupported DB engine: {engine}")

    def _alter_user_password(self, master_dict, target_username, new_password):
        """Run ALTER USER / SET PASSWORD against the master connection."""
        engine = os.environ.get(
            "DB_ENGINE", master_dict.get("engine", "postgres")
        ).lower()
        conn = self._get_connection(master_dict)
        try:
            conn.autocommit = True
            with conn.cursor() as cur:
                if engine == "postgres":
                    cur.execute(
                        "ALTER USER %s WITH PASSWORD %s",
                        (target_username, new_password),
                    )
                else:
                    cur.execute(
                        "ALTER USER %s@'%%' IDENTIFIED BY %s",
                        (target_username, new_password),
                    )
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # Post-rotation cycling helpers
    # ------------------------------------------------------------------

    def _cycle_ecs(self):
        cluster = os.environ.get("ECS_CLUSTER")
        service = os.environ.get("ECS_SERVICE")
        if not cluster or not service:
            return
        logger.info("Forcing new ECS deployment: cluster=%s service=%s", cluster, service)
        ecs = boto3.client("ecs")
        ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)

    def _cycle_k8s(self):
        namespace = os.environ.get("K8S_NAMESPACE")
        deployment = os.environ.get("K8S_DEPLOYMENT")
        if not namespace or not deployment:
            return
        logger.info(
            "Triggering Kubernetes rollout restart: namespace=%s deployment=%s",
            namespace,
            deployment,
        )
        try:
            from kubernetes import client as k8s_client, config as k8s_config  # noqa: PLC0415

            if os.environ.get("K8S_IN_CLUSTER", "true").lower() == "true":
                k8s_config.load_incluster_config()
            else:
                kubeconfig_arn = os.environ.get("KUBECONFIG_SECRET_ARN")
                if kubeconfig_arn:
                    kubeconfig_yaml = self._client.get_secret_value(
                        SecretId=kubeconfig_arn
                    )["SecretString"]
                    import tempfile  # noqa: PLC0415
                    with tempfile.NamedTemporaryFile(
                        mode="w", suffix=".yaml", delete=False
                    ) as f:
                        f.write(kubeconfig_yaml)
                        k8s_config.load_kube_config(config_file=f.name)
                else:
                    k8s_config.load_kube_config()

            now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
            patch = {
                "spec": {
                    "template": {
                        "metadata": {
                            "annotations": {"kubectl.kubernetes.io/restartedAt": now}
                        }
                    }
                }
            }
            apps_v1 = k8s_client.AppsV1Api()
            apps_v1.patch_namespaced_deployment(
                name=deployment, namespace=namespace, body=patch
            )
        except ImportError:
            logger.warning(
                "kubernetes package not installed; skipping pod rollout restart"
            )


class _SingleRotationHandler(_BaseRotationHandler):
    """Rotate a single username/password in-place."""

    def create_secret(self, secret_arn, token):
        try:
            self._get_secret_value(secret_arn, _PENDING_SUFFIX)
            logger.info("Pending secret already exists for token %s", token)
            return
        except self._client.exceptions.ResourceNotFoundException:
            pass

        current = self._get_secret_value(secret_arn, _CURRENT_SUFFIX)
        pending = dict(current)
        pending["password"] = self._generate_password()
        self._put_secret_value(secret_arn, token, pending)
        logger.info("Created pending secret for token %s", token)

    def set_secret(self, secret_arn, token):
        pending = self._get_secret_value(secret_arn, _PENDING_SUFFIX)
        master_arn = os.environ.get("MASTER_SECRET_ARN")
        master = (
            self._get_secret_value(master_arn, _CURRENT_SUFFIX)
            if master_arn
            else pending
        )
        self._alter_user_password(master, pending["username"], pending["password"])
        logger.info("Password updated in database for user %s", pending["username"])

    def test_secret(self, secret_arn, token):
        pending = self._get_secret_value(secret_arn, _PENDING_SUFFIX)
        conn = self._get_connection(pending)
        conn.close()
        logger.info("Test connection succeeded for user %s", pending["username"])

    def finish_secret(self, secret_arn, token):
        metadata = self._client.describe_secret(SecretId=secret_arn)
        current_version = next(
            (
                v
                for v, stages in metadata["VersionIdsToStages"].items()
                if _CURRENT_SUFFIX in stages
            ),
            None,
        )
        if current_version == token:
            logger.info("Token %s is already AWSCURRENT", token)
            return
        self._client.update_secret_version_stage(
            SecretId=secret_arn,
            VersionStage=_CURRENT_SUFFIX,
            MoveToVersionId=token,
            RemoveFromVersionId=current_version,
        )
        logger.info("Rotation finished – token %s is now AWSCURRENT", token)
        self._cycle_ecs()
        self._cycle_k8s()


class _AbRotationHandler(_BaseRotationHandler):
    """
    A/B rotation – alternates between <base>_a and <base>_b usernames.

    The current secret's username is the *active* account.  During rotation
    the *inactive* account's password is updated in the database and the
    secret is updated to point at that account.  Until finishSecret is called
    both accounts have valid passwords, providing a soft handoff window.
    """

    @staticmethod
    def _get_inactive_username(current_username):
        """Derive the inactive username from the current active username."""
        for suffix in _AB_SUFFIXES:
            if current_username.endswith(suffix):
                base = current_username[: -len(suffix)]
                other = next(s for s in _AB_SUFFIXES if s != suffix)
                return base + other
        # No recognised suffix – append _b as the inactive counterpart.
        return current_username + "_b"

    def create_secret(self, secret_arn, token):
        try:
            self._get_secret_value(secret_arn, _PENDING_SUFFIX)
            logger.info("Pending secret already exists for token %s", token)
            return
        except self._client.exceptions.ResourceNotFoundException:
            pass

        current = self._get_secret_value(secret_arn, _CURRENT_SUFFIX)
        inactive_username = self._get_inactive_username(current["username"])
        pending = dict(current)
        pending["username"] = inactive_username
        pending["password"] = self._generate_password()
        self._put_secret_value(secret_arn, token, pending)
        logger.info(
            "Created pending secret: switching from %s to %s",
            current["username"],
            inactive_username,
        )

    def set_secret(self, secret_arn, token):
        pending = self._get_secret_value(secret_arn, _PENDING_SUFFIX)
        master_arn = os.environ.get("MASTER_SECRET_ARN")
        if not master_arn:
            raise ValueError(
                "MASTER_SECRET_ARN must be set for A/B rotation to ALTER USER passwords"
            )
        master = self._get_secret_value(master_arn, _CURRENT_SUFFIX)
        self._alter_user_password(master, pending["username"], pending["password"])
        logger.info(
            "Password set in database for inactive user %s", pending["username"]
        )

    def test_secret(self, secret_arn, token):
        pending = self._get_secret_value(secret_arn, _PENDING_SUFFIX)
        conn = self._get_connection(pending)
        conn.close()
        logger.info(
            "Test connection succeeded for inactive user %s", pending["username"]
        )

    def finish_secret(self, secret_arn, token):
        metadata = self._client.describe_secret(SecretId=secret_arn)
        current_version = next(
            (
                v
                for v, stages in metadata["VersionIdsToStages"].items()
                if _CURRENT_SUFFIX in stages
            ),
            None,
        )
        if current_version == token:
            logger.info("Token %s is already AWSCURRENT", token)
            return
        self._client.update_secret_version_stage(
            SecretId=secret_arn,
            VersionStage=_CURRENT_SUFFIX,
            MoveToVersionId=token,
            RemoveFromVersionId=current_version,
        )
        logger.info("Rotation finished – token %s is now AWSCURRENT", token)
        self._cycle_ecs()
        self._cycle_k8s()


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def _secrets_client():
    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION"))
    return boto3.client("secretsmanager", region_name=region)


# ---------------------------------------------------------------------------
# Stand-alone entry-point (Helm chart CronJob mode)
# ---------------------------------------------------------------------------

def rotate_secret_cli():
    """
    Minimal CLI wrapper used when the script runs as a Kubernetes CronJob.

    Required environment variables (in addition to the ones above):
      SECRET_ARN   – the ARN of the secret to rotate.
    """
    secret_arn = os.environ["SECRET_ARN"]
    client = _secrets_client()

    logger.info("Initiating rotation for secret %s", secret_arn)
    response = client.rotate_secret(SecretId=secret_arn)
    logger.info(
        "Rotation initiated – VersionId: %s", response.get("VersionId", "n/a")
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    rotate_secret_cli()
