#!/usr/bin/env python3
"""Unit tests for lib/parse_provider.py.

Runs the parser as a subprocess (exactly as trigon-up.sh does) and evaluates its
output through bash, so each test verifies the real contract: the emitted
PROVIDER_* lines are correct *and* safe to `eval`.

Run: python3 -m unittest discover -s tests
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PARSER = REPO / "lib" / "parse_provider.py"
PROVIDERS = REPO / "providers"

VARS = [
    "PROVIDER_TYPE", "PROVIDER_BASE_URL", "PROVIDER_MODEL",
    "PROVIDER_API_KEY_ENV", "PROVIDER_LITELLM_PREFIX",
    "PROVIDER_LITELLM_API_BASE", "PROVIDER_REQUIRES",
    "PROVIDER_NOTES", "PROVIDER_SUPPORTS_THINKING",
]


def parse(provider_file, model_spec=""):
    """Run the parser, eval its output in bash, return {VAR: value}."""
    out = subprocess.run(
        ["python3", str(PARSER), str(provider_file), model_spec],
        capture_output=True, text=True, check=True,
    ).stdout
    # eval the shell assignments, then print each var on its own line.
    script = 'eval "$1"\n' + "".join(f'printf "%s\\n" "${{{v}}}"\n' for v in VARS)
    evaled = subprocess.run(
        ["bash", "-c", script, "_", out],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    return dict(zip(VARS, evaled))


class TestRealProviders(unittest.TestCase):
    """Codifies the behavioural baseline captured during the lib/ extraction."""

    def test_anthropic_direct(self):
        d = parse(PROVIDERS / "anthropic.yml")
        self.assertEqual(d["PROVIDER_TYPE"], "direct")
        self.assertEqual(d["PROVIDER_MODEL"], "claude-sonnet-4-6")
        self.assertEqual(d["PROVIDER_API_KEY_ENV"], "ANTHROPIC_API_KEY")
        self.assertEqual(d["PROVIDER_REQUIRES"], "")

    def test_deepseek_litellm(self):
        d = parse(PROVIDERS / "deepseek.yml")
        self.assertEqual(d["PROVIDER_TYPE"], "litellm-proxy")
        self.assertEqual(d["PROVIDER_MODEL"], "deepseek-v4-flash")
        self.assertEqual(d["PROVIDER_LITELLM_PREFIX"], "deepseek/")
        self.assertEqual(d["PROVIDER_REQUIRES"], "DEEPSEEK_API_KEY")

    def test_bedrock_multi_requires(self):
        d = parse(PROVIDERS / "bedrock.yml")
        self.assertEqual(d["PROVIDER_TYPE"], "litellm-proxy")
        self.assertEqual(
            d["PROVIDER_REQUIRES"],
            "AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION",
        )

    def test_supports_thinking_false(self):
        d = parse(PROVIDERS / "spark-foundationsec.yml")
        self.assertEqual(d["PROVIDER_SUPPORTS_THINKING"], "false")

    def test_all_providers_parse(self):
        for f in sorted(PROVIDERS.glob("*.yml")):
            with self.subTest(provider=f.name):
                d = parse(f)
                self.assertTrue(d["PROVIDER_TYPE"])  # every provider has a type


class TestModelResolution(unittest.TestCase):
    def test_model_map_alias(self):
        # deepseek:smart resolves through model_map
        d = parse(PROVIDERS / "deepseek.yml", "smart")
        self.assertEqual(d["PROVIDER_MODEL"], "deepseek-v4-pro")

    def test_explicit_model_overrides_default(self):
        d = parse(PROVIDERS / "ollama.yml", "qwen2.5-coder:7b")
        self.assertEqual(d["PROVIDER_MODEL"], "qwen2.5-coder:7b")

    def test_default_model_when_unspecified(self):
        d = parse(PROVIDERS / "openrouter.yml")
        self.assertEqual(d["PROVIDER_MODEL"], "deepseek/deepseek-r1")

    def test_unknown_alias_passed_through_as_literal_model(self):
        # A spec that isn't a model_map key is used verbatim as the model.
        d = parse(PROVIDERS / "deepseek.yml", "deepseek-some-future-model")
        self.assertEqual(d["PROVIDER_MODEL"], "deepseek-some-future-model")


class TestQuotingSafety(unittest.TestCase):
    def test_single_quote_in_value_is_eval_safe(self):
        # A notes field containing a single quote must survive eval unmangled.
        with tempfile.NamedTemporaryFile(
            "w", suffix=".yml", delete=False, dir="/tmp"
        ) as tf:
            tf.write("type: direct\n")
            tf.write("default_model: m\n")
            tf.write("notes: it's a \"tricky\" value\n")
            path = tf.name
        d = parse(path)
        self.assertEqual(d["PROVIDER_NOTES"], 'it\'s a "tricky" value')


if __name__ == "__main__":
    unittest.main()
