#!/usr/bin/env python3
"""Parse a Trigon provider YAML file into shell-eval'able assignments.

Usage:
    parse_provider.py PROVIDER_FILE [MODEL_SPEC]

Reads a `providers/*.yml` file (see providers/schema.md) using a deliberately
tiny, dependency-free YAML subset parser — Trigon requires only a stock
`python3` on the host, no `pip` packages. The provider files use a flat
key/value layout with two nested sections (`model_map`, `requires`), which is
all this parser needs to understand.

It prints `KEY='value'` lines on stdout, single-quote-escaped so the caller can
safely `eval` the output:

    PROVIDER_VARS="$(python3 lib/parse_provider.py "$file" "$spec")"
    eval "$PROVIDER_VARS"

MODEL_SPEC (optional) overrides `default_model`; if it matches a `model_map`
alias (e.g. `smart`) it is resolved to the aliased model name.
"""
import sys

path = sys.argv[1]
model_spec = sys.argv[2] if len(sys.argv) > 2 else ""

data = {
    'type': '', 'base_url': '', 'default_model': '',
    'api_key_env': '', 'litellm_model_prefix': '',
    'litellm_api_base': '', 'notes': '',
    'supports_thinking': '',
    'model_map': {}, 'requires': [],
}

section = None
with open(path) as f:
    for line in f:
        line = line.rstrip()
        if not line or line.lstrip().startswith('#'):
            continue
        if line[:1] in (' ', '\t'):
            s = line.strip()
            if section == 'model_map' and ':' in s:
                k, _, v = s.partition(':')
                data['model_map'][k.strip()] = v.strip().strip('"' "'")
            elif section == 'requires' and s.startswith('- '):
                data['requires'].append(s[2:].strip())
        else:
            if ':' in line:
                k, _, v = line.partition(':')
                k = k.strip()
                v = v.strip().strip('"' "'")
                if k in data and isinstance(data[k], (list, dict)):
                    section = k
                else:
                    data[k] = v
                    section = None

model = model_spec or data.get('default_model', '')
if model in data['model_map']:
    model = data['model_map'][model]


def sh(v):
    v = str(v) if v else ''
    return "'" + v.replace("'", "'\\''") + "'"


print(f"PROVIDER_TYPE={sh(data.get('type',''))}")
print(f"PROVIDER_BASE_URL={sh(data.get('base_url',''))}")
print(f"PROVIDER_MODEL={sh(model)}")
print(f"PROVIDER_API_KEY_ENV={sh(data.get('api_key_env',''))}")
print(f"PROVIDER_LITELLM_PREFIX={sh(data.get('litellm_model_prefix',''))}")
print(f"PROVIDER_LITELLM_API_BASE={sh(data.get('litellm_api_base',''))}")
print(f"PROVIDER_REQUIRES={sh(' '.join(data.get('requires',[])))}")
print(f"PROVIDER_NOTES={sh(data.get('notes',''))}")
print(f"PROVIDER_SUPPORTS_THINKING={sh(data.get('supports_thinking',''))}")
