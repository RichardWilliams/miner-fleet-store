"""Read and write the data files a store release bump touches.

Invoked as `python3 scripts/lib/manifest_data.py <op> ...` by the release
driver (`scripts/release.sh`) and by both new gates
(`scripts/check-release-notes-drift.sh`, `scripts/check-deploy-contract.sh`).
It is a module, not an executable: mode 644, no shebang, never `./`-run.

WHY PYTHON.  The pinned CI image carries bash, git, grep, sed and python3 and
carries neither `jq` nor `yq`, so python3 is the only parser both the container
and the operator's machine are guaranteed to have.  Everything the three
consumers need to read or write is here, once, so the writer (the driver) and
the reader (the drift gate) cannot drift apart.

FAIL-CLOSED ON INPUT IT CANNOT READ.  An operation exits non-zero with a named
diagnostic on stderr when the document defeats it: a missing file, an
unparseable document, a key that appears more than once, a value of the wrong
shape, or a body the folded-scalar emitter cannot represent faithfully.  A read
failure is never reported as a success-shaped value, because "parsed fine,
found nothing" and "could not read it" must not be the same value
(INVARIANTS.md § Encapsulation).  Enforced by the fail-closed cases in
tests/test-check-deploy-contract.sh and tests/test-check-release-notes-drift.sh,
which drive each of those inputs through the gates that call this module.

KEY PRESENCE IS DATA, AND IS A DIFFERENT QUESTION FROM READABILITY.  An absent
key is not a document this module failed to read, so the two are answered
differently and deliberately:

  * `get`, `keys`, `seq` and `len` are asked FOR a value. An absent key means
    there is no value to return, so they exit non-zero naming the path.
  * `kind` is asked WHETHER a key is there. It answers `absent` and exits 0 —
    that is the whole of what it is for. `scripts/check-deploy-contract.sh`
    branches on that answer as an ordinary case when deciding whether the
    compose declares an `environment` mapping or an `env_file` sequence, and
    tests/test-check-deploy-contract.sh's required-environment-key cases drive
    both branches.

Reading `kind`'s exit 0 as a fail-closed violation gets this backwards: making
it fail on an absent key would break the one caller that depends on the answer.

THE FOLDED-SCALAR CONTRACT.  `releaseNotes` is written as a YAML `>-` folded
block scalar, which is NOT a byte-preserving container: YAML folds the break
between two lines at the block indent into a space, keeps the break literal
when either neighbouring line is MORE indented, and `-` strips every trailing
break.  A comparison of the raw upstream body against the raw manifest text is
therefore a false block on correct input.  The emitter's rule, derived against
a real parser rather than from the spec alone, is:

  * a non-blank body line is emitted as `<indent><line>`;
  * a run of m >= 1 blank body lines is emitted as m + 1 blank lines when the
    non-blank lines on BOTH sides of the run sit at the base indent, and as m
    blank lines when either neighbour is more-indented.

The two cases differ because YAML already spends one literal break on the
transition into or out of a more-indented region, so the run only has to
supply the remaining m.  With that rule a blank-line paragraph break survives
verbatim, more-indented bullet lines keep their own breaks and their extra
indentation, and only soft-wrapped lines inside one paragraph fold to single
spaces — which is intended, is how the app manifest's `description` field is
already spelled, and is why `round-trip` exists as ONE named operation both
the writer and the reader call.
"""

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment defect, reported not hidden
    sys.stderr.write(
        "manifest-data: PyYAML is not importable; this repo's gates cannot "
        "parse YAML without it (docker/Dockerfile.ci installs python3-yaml)\n"
    )
    raise SystemExit(1)


TOOL = "manifest-data"

# A double-quoted YAML scalar written by `set-scalar` may not carry a quote or
# a backslash, because neither is escaped on the way in. Every value this repo
# writes through that operation is a semver, so the restriction costs nothing
# and a value that would need escaping fails loudly instead of silently
# producing malformed YAML.
UNQUOTABLE_RE = re.compile(r'["\\\n]')


def fail(message: str) -> None:
    """Report a named diagnostic and exit non-zero. Never returns."""
    sys.stderr.write(f"{TOOL}: {message}\n")
    raise SystemExit(1)


# --- parsing -----------------------------------------------------------------


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping carrying the same key twice.

    PyYAML's default behaviour is to keep the LAST of a set of duplicate keys,
    silently. A manifest carrying `releaseNotes` twice is ambiguous — the gate
    cannot know which copy is authoritative — so it is a failure, not a guess.
    """


def _construct_mapping_no_duplicates(loader, node, deep=False):
    seen = set()
    for key_node, _value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        seen.add(key)
    return yaml.constructor.SafeConstructor.construct_mapping(loader, node, deep=deep)


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping_no_duplicates,
)


def _json_object_no_duplicates(pairs):
    seen = set()
    built = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"found duplicate key {key!r}")
        seen.add(key)
        built[key] = value
    return built


def read_text(path: Path, what: str) -> str:
    """Read a file, failing by name on absence or on an unreadable byte stream."""
    if not path.is_file():
        fail(f"{what} not found at {path}")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{what} at {path} is unreadable: {exc}")
    raise AssertionError("unreachable")


def load_document(path: Path):
    """Parse a data file. `.json` is read as JSON, everything else as YAML.

    The vendored deployment contract is JSON and the two manifests are YAML.
    Dispatching on the suffix keeps each format on the parser that actually
    defines it, rather than leaning on the partial overlap between them, while
    both paths share this module's duplicate-key refusal.
    """
    text = read_text(path, "data file")
    if path.suffix == ".json":
        try:
            return json.loads(text, object_pairs_hook=_json_object_no_duplicates)
        except (ValueError, TypeError) as exc:
            fail(f"{path} is not parseable JSON: {exc}")
    else:
        try:
            return yaml.load(text, StrictLoader)
        except (yaml.YAMLError, ValueError) as exc:
            fail(f"{path} is not parseable YAML: {exc}")
    raise AssertionError("unreachable")


MISSING = object()


def resolve(document, segments: list[str]):
    """Walk a key path. Returns MISSING when any segment is absent.

    A segment addressing a sequence must be a decimal index; anything else at
    that position is a failure rather than a miss, because it names a shape the
    document does not have.
    """
    node = document
    walked: list[str] = []
    for segment in segments:
        walked.append(segment)
        trail = ".".join(walked)
        if isinstance(node, dict):
            if segment not in node:
                return MISSING
            node = node[segment]
        elif isinstance(node, list):
            if not re.fullmatch(r"[0-9]+", segment):
                fail(f"path segment '{trail}' addresses a sequence but is not an index")
            index = int(segment)
            if index >= len(node):
                return MISSING
            node = node[index]
        else:
            fail(f"path segment '{trail}' addresses a scalar, which has no members")
    return node


def scalar_text(node, trail: str) -> str:
    """Render a scalar for stdout, failing on any non-scalar or null."""
    if isinstance(node, bool):
        return "true" if node else "false"
    if isinstance(node, (int, float)):
        return str(node)
    if isinstance(node, str):
        return node
    if node is None:
        fail(f"'{trail}' is null, which carries no value to compare")
    fail(f"'{trail}' is a {type(node).__name__}, not a scalar")
    raise AssertionError("unreachable")


# --- the folded-scalar emitter ------------------------------------------------


def canonical_body(text: str) -> str:
    """The one definition of "the release body" both the driver and gate use.

    The vendored file is the byte-exact stdout of the upstream fetch, which
    ends in a trailing newline that a `>-` scalar cannot represent (the `-`
    chomping indicator strips exactly those). Stripping them here — in ONE
    place, called by both sides — is what makes the writer's input and the
    reader's input the same string.
    """
    return text.rstrip("\n")


def validate_body(body: str) -> None:
    """Refuse a body the folded-scalar emitter cannot represent faithfully."""
    if body == "":
        fail("the release body is empty")
    if "\r" in body:
        fail("the release body contains a carriage return; only LF line endings round-trip")
    if "\t" in body:
        fail("the release body contains a tab; YAML block indentation is spaces only")
    lines = body.split("\n")
    if lines[0][:1].isspace():
        fail(
            "the release body's first line begins with whitespace; a folded scalar "
            "takes its block indent from its first line, so a more-indented first "
            "line has no base indent to fold against"
        )
    for number, line in enumerate(lines, start=1):
        if line != line.rstrip():
            fail(
                f"the release body's line {number} ends in whitespace, which YAML "
                "folding discards, so the value would not round-trip"
            )


def emit_block(body: str, indent: int) -> str:
    """Emit a validated body as the CONTENT of a `>-` folded block scalar.

    The two blank-run widths are the whole of the rule; see this module's
    docstring for why they differ.
    """
    if indent < 1:
        fail(f"block indent {indent} is not a positive number of spaces")
    pad = " " * indent
    lines = body.split("\n")
    emitted: list[str] = []
    position = 0
    total = len(lines)
    while position < total:
        if lines[position] != "":
            emitted.append(pad + lines[position])
            position += 1
            continue
        after = position
        while after < total and lines[after] == "":
            after += 1
        run = after - position
        # validate_body guarantees a non-blank first and last line, so a blank
        # run always has a real neighbour on each side.
        previous_more_indented = lines[position - 1][:1].isspace()
        next_more_indented = lines[after][:1].isspace()
        both_at_base = not previous_more_indented and not next_more_indented
        emitted.extend([""] * (run + 1 if both_at_base else run))
        position = after
    return "\n".join(emitted)


def round_trip(body: str, indent: int) -> str:
    """Emit the body as a folded scalar and parse it straight back.

    This is the ONE named operation the release driver and the drift gate both
    call: the driver writes `emit_block(...)` into the manifest, and the gate
    compares the manifest's PARSED value against this result. Comparing the raw
    body against raw file text instead is the false-block defect the module
    docstring names.
    """
    document = "v: >-\n" + emit_block(body, indent) + "\n"
    try:
        parsed = yaml.load(document, StrictLoader)
    except yaml.YAMLError as exc:
        fail(f"the emitted folded scalar does not parse back: {exc}")
    value = parsed["v"]
    if not isinstance(value, str):
        fail(f"the emitted folded scalar parsed back as {type(value).__name__}, not a string")
    return value


# --- in-place surgery ---------------------------------------------------------


def top_level_key_line(lines: list[str], key: str, path: Path) -> int:
    """Index of the one line starting the given top-level key.

    Surgery rather than a whole-file PyYAML round-trip, because the app
    manifest carries load-bearing explanatory comments (icon hosting, gallery)
    that a re-serialisation would delete.
    """
    pattern = re.compile(r"^" + re.escape(key) + r":")
    hits = [index for index, line in enumerate(lines) if pattern.match(line)]
    if not hits:
        fail(f"no top-level '{key}:' key found in {path}")
    if len(hits) > 1:
        fail(
            f"{len(hits)} top-level '{key}:' keys found in {path} — expected exactly "
            "one; cannot determine which is authoritative"
        )
    return hits[0]


def set_scalar(path: Path, key: str, value: str) -> None:
    """Replace a top-level scalar's value, preserving any trailing comment."""
    if UNQUOTABLE_RE.search(value):
        fail(f"value {value!r} carries a quote, backslash or newline and cannot be written")
    lines = read_text(path, "manifest").split("\n")
    index = top_level_key_line(lines, key, path)
    match = re.match(
        r"^(" + re.escape(key) + r":[ \t]+)(\"[^\"]*\"|'[^']*'|[^ \t#]+)(.*)$",
        lines[index],
    )
    if match is None:
        fail(f"the '{key}:' line in {path} carries no value this operation can replace")
    lines[index] = f'{match.group(1)}"{value}"{match.group(3)}'
    path.write_text("\n".join(lines), encoding="utf-8")


def set_block(path: Path, key: str, body: str, indent: int) -> None:
    """Replace a top-level folded block scalar with a freshly emitted one.

    The replaced span runs from the key line to the last indented line beneath
    it. Blank lines trailing that span are left where they are: they belong to
    the file's layout, and `-` chomping means they carry no value either way.
    """
    validate_body(body)
    block = emit_block(body, indent)
    lines = read_text(path, "manifest").split("\n")
    index = top_level_key_line(lines, key, path)
    last = index
    cursor = index + 1
    while cursor < len(lines):
        if lines[cursor].strip() == "":
            cursor += 1
            continue
        if lines[cursor][:1] in (" ", "\t"):
            last = cursor
            cursor += 1
            continue
        break
    replacement = [f"{key}: >-"] + block.split("\n")
    lines[index : last + 1] = replacement
    path.write_text("\n".join(lines), encoding="utf-8")


# --- command line -------------------------------------------------------------

USAGE = """usage:
  manifest_data.py kind       <file> <path...>
  manifest_data.py get        <file> <path...>
  manifest_data.py keys       <file> <path...>
  manifest_data.py seq        <file> <path...>
  manifest_data.py len        <file> <path...>
  manifest_data.py round-trip <body-file> <indent>
  manifest_data.py set-scalar <file> <key> <value>
  manifest_data.py set-block  <file> <key> <body-file> <indent>"""


def positive_int(text: str, what: str) -> int:
    if not re.fullmatch(r"[0-9]+", text):
        fail(f"{what} '{text}' is not a whole number")
    return int(text)


def node_for(argv: list[str], operation: str):
    if len(argv) < 2:
        fail(f"'{operation}' needs a file and at least one path segment")
    path = Path(argv[0])
    segments = argv[1:]
    node = resolve(load_document(path), segments)
    return node, ".".join(segments), path


def run_kind(argv: list[str]) -> None:
    node, _trail, _path = node_for(argv, "kind")
    if node is MISSING:
        print("absent")
    elif node is None:
        print("null")
    elif isinstance(node, dict):
        print("mapping")
    elif isinstance(node, list):
        print("sequence")
    else:
        print("scalar")


def run_get(argv: list[str]) -> None:
    node, trail, path = node_for(argv, "get")
    if node is MISSING:
        fail(f"no '{trail}' found in {path}")
    sys.stdout.write(scalar_text(node, trail))
    sys.stdout.write("\n")


def run_keys(argv: list[str]) -> None:
    node, trail, path = node_for(argv, "keys")
    if node is MISSING:
        fail(f"no '{trail}' found in {path}")
    if not isinstance(node, dict):
        fail(f"'{trail}' in {path} is a {type(node).__name__}, not a mapping")
    for key in node:
        print(scalar_text(key, trail))


def run_seq(argv: list[str]) -> None:
    node, trail, path = node_for(argv, "seq")
    if node is MISSING:
        fail(f"no '{trail}' found in {path}")
    if not isinstance(node, list):
        fail(f"'{trail}' in {path} is a {type(node).__name__}, not a sequence")
    for position, item in enumerate(node):
        print(scalar_text(item, f"{trail}[{position}]"))


def run_len(argv: list[str]) -> None:
    node, trail, path = node_for(argv, "len")
    if node is MISSING:
        fail(f"no '{trail}' found in {path}")
    if not isinstance(node, list):
        fail(f"'{trail}' in {path} is a {type(node).__name__}, not a sequence")
    print(len(node))


def run_round_trip(argv: list[str]) -> None:
    if len(argv) != 2:
        fail("'round-trip' needs a body file and a block indent")
    body = canonical_body(read_text(Path(argv[0]), "release body"))
    validate_body(body)
    sys.stdout.write(round_trip(body, positive_int(argv[1], "block indent")))
    sys.stdout.write("\n")


def run_set_scalar(argv: list[str]) -> None:
    if len(argv) != 3:
        fail("'set-scalar' needs a file, a key and a value")
    set_scalar(Path(argv[0]), argv[1], argv[2])


def run_set_block(argv: list[str]) -> None:
    if len(argv) != 4:
        fail("'set-block' needs a file, a key, a body file and a block indent")
    body = canonical_body(read_text(Path(argv[2]), "release body"))
    set_block(Path(argv[0]), argv[1], body, positive_int(argv[3], "block indent"))


OPERATIONS = {
    "kind": run_kind,
    "get": run_get,
    "keys": run_keys,
    "seq": run_seq,
    "len": run_len,
    "round-trip": run_round_trip,
    "set-scalar": run_set_scalar,
    "set-block": run_set_block,
}


def main(argv: list[str]) -> None:
    if not argv or argv[0] not in OPERATIONS:
        fail(f"unknown or missing operation\n{USAGE}")
    OPERATIONS[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
