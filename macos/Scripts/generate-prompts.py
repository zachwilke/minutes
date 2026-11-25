#!/usr/bin/env python3
"""Generates Swift constants from the shared prompt JSON.

The JSON in shared/prompts/ is canonical: it is what the Windows port reads too.
Generating code rather than loading the files at runtime is deliberate — a
missing or malformed resource would fail at the worst possible moment (the end of
a meeting), whereas a generation step fails at build time on the developer's
machine.

Usage:
  generate-prompts.py            write Sources/Minutes/Generated/Prompts.swift
  generate-prompts.py --check    exit non-zero if the file is stale
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT.parent / "shared" / "prompts"
OUT = ROOT / "Sources" / "Minutes" / "Generated" / "Prompts.swift"


def swift_string(text):
    """A single-line Swift literal. Deliberately not a multi-line literal:
    those strip indentation based on the closing delimiter, which is exactly
    the subtlety that could silently alter a prompt."""
    escaped = (text.replace("\\", "\\\\")
                   .replace('"', '\\"')
                   .replace("\n", "\\n")
                   .replace("\t", "\\t")
                   .replace("\r", "\\r"))
    return f'"{escaped}"'


def generate():
    summary = json.loads((SHARED / "summary.json").read_text(encoding="utf-8"))
    chat = json.loads((SHARED / "chat.json").read_text(encoding="utf-8"))
    detection = json.loads((SHARED / "detection-apps.json").read_text(encoding="utf-8"))
    recipes = json.loads((SHARED / "recipes.json").read_text(encoding="utf-8"))

    lines = [
        "// GENERATED FILE — DO NOT EDIT.",
        "//",
        "// Source of truth: shared/prompts/*.json",
        "// Regenerate:      macos/Scripts/generate-prompts.py",
        "//",
        "// The prompts are shared with the Windows port, so editing them here",
        "// would silently desynchronise the two apps. Edit the JSON instead.",
        "",
        "enum SharedPrompts {",
        "    enum Summary {",
        f"        static let systemPrompt = {swift_string(summary['systemPrompt'])}",
        f"        static let notesGuidance = {swift_string(summary['notesGuidance'])}",
        f"        static let notesNone = {swift_string(summary['notesNone'])}",
        f"        static let transcriptGuidance = {swift_string(summary['transcriptGuidance'])}",
        f"        static let closingGuidance = {swift_string(summary['closingGuidance'])}",
        f"        static let languageInstruction = {swift_string(summary['languageInstruction'])}",
        f"        static let titleInstruction = {swift_string(summary['titleInstruction'])}",
        f"        static let recordedByLine = {swift_string(summary['recordedByLine'])}",
        "",
        "        struct Template {",
        "            let id: String",
        "            let name: String",
        "            let blurb: String",
        "            let instructions: String",
        "        }",
        "",
        "        static let templates: [Template] = [",
    ]
    for t in summary["templates"]:
        lines.append("            Template(id: %s," % swift_string(t["id"]))
        lines.append("                     name: %s," % swift_string(t["name"]))
        lines.append("                     blurb: %s," % swift_string(t["blurb"]))
        lines.append("                     instructions: %s)," % swift_string(t["instructions"]))
    lines += [
        "        ]",
        "    }",
        "",
        "    enum Chat {",
        f"        static let systemPrompt = {swift_string(chat['systemPrompt'])}",
        f"        static let indexNote = {swift_string(chat['indexNote'])}",
        f"        static let coverageNote = {swift_string(chat['coverageNote'])}",
        f"        static let userLine = {swift_string(chat['userLine'])}",
        "    }",
        "",
        "    enum Detection {",
        "        struct App {",
        "            let prefix: String",
        "            let name: String",
        "            let ambiguous: Bool",
        "        }",
        "",
        "        static let apps: [App] = [",
    ]
    for a in detection["apps"]:
        lines.append("            App(prefix: %s, name: %s, ambiguous: %s),"
                     % (swift_string(a["prefix"]), swift_string(a["name"]),
                        "true" if a["ambiguous"] else "false"))
    lines += [
        "        ]",
        "    }",
        "",
        "    enum Recipes {",
        "        struct Recipe {",
        "            let id: String",
        "            let title: String",
        "            /// \"meeting\", \"library\" or \"any\".",
        "            let scope: String",
        "            let prompt: String",
        "        }",
        "",
        "        static let all: [Recipe] = [",
    ]
    for r in recipes["recipes"]:
        lines.append("            Recipe(id: %s," % swift_string(r["id"]))
        lines.append("                   title: %s," % swift_string(r["title"]))
        lines.append("                   scope: %s," % swift_string(r["scope"]))
        lines.append("                   prompt: %s)," % swift_string(r["prompt"]))
    lines += ["        ]", "    }", "}", ""]
    return "\n".join(lines)


def main():
    generated = generate()
    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != generated:
            print("error: Prompts.swift is stale — run macos/Scripts/generate-prompts.py",
                  file=sys.stderr)
            return 1
        print("    prompts up to date")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(generated, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(generated)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
