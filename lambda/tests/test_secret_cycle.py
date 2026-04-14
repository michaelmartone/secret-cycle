"""Unit tests for secret_cycle.py."""
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Stub out heavy optional dependencies before importing the module under test
# ---------------------------------------------------------------------------

# psycopg2
psycopg2_stub = types.ModuleType("psycopg2")
psycopg2_stub.connect = MagicMock()
sys.modules.setdefault("psycopg2", psycopg2_stub)

# pymysql
pymysql_stub = types.ModuleType("pymysql")
pymysql_stub.connect = MagicMock()
sys.modules.setdefault("pymysql", pymysql_stub)

# kubernetes (optional – only needed for K8s cycling)
k8s_stub = types.ModuleType("kubernetes")
k8s_stub.client = types.ModuleType("kubernetes.client")
k8s_stub.config = types.ModuleType("kubernetes.config")
sys.modules.setdefault("kubernetes", k8s_stub)
sys.modules.setdefault("kubernetes.client", k8s_stub.client)
sys.modules.setdefault("kubernetes.config", k8s_stub.config)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import secret_cycle  # noqa: E402  – must come after stubs


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_client(current_secret, pending_secret=None):
    """Return a mock boto3 secretsmanager client."""
    client = MagicMock()

    def _get_secret_value(SecretId, VersionStage):  # noqa: N803
        if VersionStage == "AWSCURRENT":
            return {"SecretString": json.dumps(current_secret)}
        if VersionStage == "AWSPENDING":
            if pending_secret is None:
                raise client.exceptions.ResourceNotFoundException(
                    {"Error": {"Code": "ResourceNotFoundException", "Message": ""}},
                    "GetSecretValue",
                )
            return {"SecretString": json.dumps(pending_secret)}
        raise ValueError(f"Unknown stage: {VersionStage}")

    client.get_secret_value.side_effect = _get_secret_value

    def _describe_secret(SecretId):  # noqa: N803
        return {
            "RotationEnabled": True,
            "VersionIdsToStages": {
                "tok-current": ["AWSCURRENT"],
                "tok-pending": ["AWSPENDING"],
            },
        }

    client.describe_secret.side_effect = _describe_secret
    client.exceptions = MagicMock()
    client.exceptions.ResourceNotFoundException = type(
        "ResourceNotFoundException", (Exception,), {}
    )
    return client


_BASE_SECRET = {
    "username": "myapp_a",
    "password": "old-password",
    "host": "db.example.com",
    "port": 5432,
    "dbname": "mydb",
    "engine": "postgres",
}


# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------

class TestGeneratePassword(unittest.TestCase):
    def test_default_length(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PASSWORD_LENGTH", None)
            pwd = secret_cycle._BaseRotationHandler._generate_password()
        self.assertEqual(len(pwd), secret_cycle._DEFAULT_PASSWORD_LENGTH)

    def test_custom_length(self):
        with patch.dict(os.environ, {"PASSWORD_LENGTH": "20"}):
            pwd = secret_cycle._BaseRotationHandler._generate_password()
        self.assertEqual(len(pwd), 20)

    def test_excludes_characters(self):
        with patch.dict(os.environ, {"EXCLUDE_CHARACTERS": "aeiou"}):
            pwd = secret_cycle._BaseRotationHandler._generate_password()
        for ch in "aeiou":
            self.assertNotIn(ch, pwd)

    def test_uniqueness(self):
        passwords = {secret_cycle._BaseRotationHandler._generate_password() for _ in range(10)}
        self.assertGreater(len(passwords), 1)


# ---------------------------------------------------------------------------
# A/B username derivation
# ---------------------------------------------------------------------------

class TestAbUsernameDerivation(unittest.TestCase):
    def test_a_to_b(self):
        self.assertEqual(
            secret_cycle._AbRotationHandler._get_inactive_username("myapp_a"),
            "myapp_b",
        )

    def test_b_to_a(self):
        self.assertEqual(
            secret_cycle._AbRotationHandler._get_inactive_username("myapp_b"),
            "myapp_a",
        )

    def test_no_suffix_appends_b(self):
        self.assertEqual(
            secret_cycle._AbRotationHandler._get_inactive_username("myapp"),
            "myapp_b",
        )


# ---------------------------------------------------------------------------
# Single rotation handler – unit tests
# ---------------------------------------------------------------------------

class TestSingleRotationCreateSecret(unittest.TestCase):
    def setUp(self):
        self.client = _make_client(_BASE_SECRET, pending_secret=None)
        self.handler = secret_cycle._SingleRotationHandler(self.client)

    def test_creates_pending_when_absent(self):
        self.handler.create_secret("arn:secret", "tok-pending")
        self.client.put_secret_value.assert_called_once()
        put_kwargs = self.client.put_secret_value.call_args[1]
        pending = json.loads(put_kwargs["SecretString"])
        self.assertEqual(pending["username"], "myapp_a")
        self.assertNotEqual(pending["password"], "old-password")

    def test_skips_when_pending_exists(self):
        client = _make_client(_BASE_SECRET, pending_secret=_BASE_SECRET)
        handler = secret_cycle._SingleRotationHandler(client)
        handler.create_secret("arn:secret", "tok-pending")
        client.put_secret_value.assert_not_called()


class TestSingleRotationFinishSecret(unittest.TestCase):
    def test_promotes_pending_to_current(self):
        client = _make_client(_BASE_SECRET)
        handler = secret_cycle._SingleRotationHandler(client)
        with patch.object(handler, "_cycle_ecs"), patch.object(handler, "_cycle_k8s"):
            handler.finish_secret("arn:secret", "tok-pending")
        client.update_secret_version_stage.assert_called_once_with(
            SecretId="arn:secret",
            VersionStage="AWSCURRENT",
            MoveToVersionId="tok-pending",
            RemoveFromVersionId="tok-current",
        )

    def test_noop_when_already_current(self):
        client = _make_client(_BASE_SECRET)
        # Simulate token already being AWSCURRENT.
        client.describe_secret.side_effect = lambda SecretId: {
            "RotationEnabled": True,
            "VersionIdsToStages": {"tok-current": ["AWSCURRENT"]},
        }
        handler = secret_cycle._SingleRotationHandler(client)
        handler.finish_secret("arn:secret", "tok-current")
        client.update_secret_version_stage.assert_not_called()


# ---------------------------------------------------------------------------
# A/B rotation handler – unit tests
# ---------------------------------------------------------------------------

class TestAbRotationCreateSecret(unittest.TestCase):
    def setUp(self):
        self.client = _make_client(_BASE_SECRET, pending_secret=None)
        self.handler = secret_cycle._AbRotationHandler(self.client)

    def test_switches_to_inactive_username(self):
        self.handler.create_secret("arn:secret", "tok-pending")
        self.client.put_secret_value.assert_called_once()
        put_kwargs = self.client.put_secret_value.call_args[1]
        pending = json.loads(put_kwargs["SecretString"])
        self.assertEqual(pending["username"], "myapp_b")

    def test_new_password_is_different(self):
        self.handler.create_secret("arn:secret", "tok-pending")
        put_kwargs = self.client.put_secret_value.call_args[1]
        pending = json.loads(put_kwargs["SecretString"])
        self.assertNotEqual(pending["password"], "old-password")

    def test_skips_when_pending_exists(self):
        pending = dict(_BASE_SECRET, username="myapp_b", password="new-pw")
        client = _make_client(_BASE_SECRET, pending_secret=pending)
        handler = secret_cycle._AbRotationHandler(client)
        handler.create_secret("arn:secret", "tok-pending")
        client.put_secret_value.assert_not_called()


class TestAbRotationSetSecret(unittest.TestCase):
    def test_requires_master_secret_arn(self):
        pending = dict(_BASE_SECRET, username="myapp_b", password="new-pw")
        client = _make_client(_BASE_SECRET, pending_secret=pending)
        handler = secret_cycle._AbRotationHandler(client)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MASTER_SECRET_ARN", None)
            with self.assertRaises(ValueError, msg="MASTER_SECRET_ARN"):
                handler.set_secret("arn:secret", "tok-pending")

    def test_calls_alter_user(self):
        master_secret = dict(_BASE_SECRET, username="admin", password="master-pw")
        pending = dict(_BASE_SECRET, username="myapp_b", password="new-pw")

        client = MagicMock()
        client.exceptions = MagicMock()
        client.exceptions.ResourceNotFoundException = type(
            "ResourceNotFoundException", (Exception,), {}
        )

        def _get(SecretId, VersionStage):  # noqa: N803
            if SecretId == "arn:master" and VersionStage == "AWSCURRENT":
                return {"SecretString": json.dumps(master_secret)}
            if SecretId == "arn:secret" and VersionStage == "AWSPENDING":
                return {"SecretString": json.dumps(pending)}
            raise ValueError("unexpected get_secret_value call")

        client.get_secret_value.side_effect = _get

        handler = secret_cycle._AbRotationHandler(client)
        with patch.dict(os.environ, {"MASTER_SECRET_ARN": "arn:master"}):
            with patch.object(handler, "_alter_user_password") as mock_alter:
                handler.set_secret("arn:secret", "tok-pending")
                mock_alter.assert_called_once_with(master_secret, "myapp_b", "new-pw")


class TestAbRotationFinishSecret(unittest.TestCase):
    def test_promotes_pending_to_current(self):
        pending = dict(_BASE_SECRET, username="myapp_b", password="new-pw")
        client = _make_client(_BASE_SECRET, pending_secret=pending)
        handler = secret_cycle._AbRotationHandler(client)
        with patch.object(handler, "_cycle_ecs"), patch.object(handler, "_cycle_k8s"):
            handler.finish_secret("arn:secret", "tok-pending")
        client.update_secret_version_stage.assert_called_once()


# ---------------------------------------------------------------------------
# ECS cycling
# ---------------------------------------------------------------------------

class TestCycleEcs(unittest.TestCase):
    def test_force_deployment_called(self):
        handler = secret_cycle._BaseRotationHandler(MagicMock())
        mock_ecs = MagicMock()
        env = {"ECS_CLUSTER": "my-cluster", "ECS_SERVICE": "my-service"}
        with patch.dict(os.environ, env):
            with patch("boto3.client", return_value=mock_ecs):
                handler._cycle_ecs()
        mock_ecs.update_service.assert_called_once_with(
            cluster="my-cluster", service="my-service", forceNewDeployment=True
        )

    def test_skipped_when_env_absent(self):
        handler = secret_cycle._BaseRotationHandler(MagicMock())
        env_copy = {k: v for k, v in os.environ.items()}
        env_copy.pop("ECS_CLUSTER", None)
        env_copy.pop("ECS_SERVICE", None)
        with patch.dict(os.environ, env_copy, clear=True):
            with patch("boto3.client") as mock_boto:
                handler._cycle_ecs()
        mock_boto.assert_not_called()


# ---------------------------------------------------------------------------
# lambda_handler dispatch
# ---------------------------------------------------------------------------

class TestLambdaHandler(unittest.TestCase):
    def _event(self, step):
        return {"SecretId": "arn:secret", "ClientRequestToken": "tok-pending", "Step": step}

    def _mock_client(self):
        client = MagicMock()
        client.describe_secret.return_value = {
            "RotationEnabled": True,
            "VersionIdsToStages": {"tok-pending": ["AWSPENDING"]},
        }
        return client

    def test_invalid_step_raises(self):
        client = self._mock_client()
        with patch("secret_cycle._secrets_client", return_value=client):
            with self.assertRaises(ValueError):
                secret_cycle.lambda_handler(self._event("badStep"), None)

    def test_already_current_returns_early(self):
        client = self._mock_client()
        client.describe_secret.return_value = {
            "RotationEnabled": True,
            "VersionIdsToStages": {"tok-pending": ["AWSCURRENT"]},
        }
        with patch("secret_cycle._secrets_client", return_value=client):
            # Should not raise and should return early (no handler method called)
            secret_cycle.lambda_handler(self._event("createSecret"), None)

    def test_rotation_not_enabled_raises(self):
        client = self._mock_client()
        client.describe_secret.return_value = {"RotationEnabled": False, "VersionIdsToStages": {}}
        with patch("secret_cycle._secrets_client", return_value=client):
            with self.assertRaises(ValueError):
                secret_cycle.lambda_handler(self._event("createSecret"), None)

    def test_dispatches_create_secret_single(self):
        client = self._mock_client()
        with patch("secret_cycle._secrets_client", return_value=client):
            with patch.dict(os.environ, {"ROTATION_TYPE": "single"}):
                with patch.object(
                    secret_cycle._SingleRotationHandler, "create_secret"
                ) as mock_create:
                    secret_cycle.lambda_handler(self._event("createSecret"), None)
                    mock_create.assert_called_once()

    def test_dispatches_create_secret_ab(self):
        client = self._mock_client()
        with patch("secret_cycle._secrets_client", return_value=client):
            with patch.dict(os.environ, {"ROTATION_TYPE": "ab"}):
                with patch.object(
                    secret_cycle._AbRotationHandler, "create_secret"
                ) as mock_create:
                    secret_cycle.lambda_handler(self._event("createSecret"), None)
                    mock_create.assert_called_once()


if __name__ == "__main__":
    unittest.main()
