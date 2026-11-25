#!/usr/bin/env python3
"""Generates C# constants from the shared prompt JSON.

Mirror of macos/Scripts/generate-prompts.py. The JSON in shared/prompts/ is
canonical for both platforms; generating code rather than reading the files at
runtime keeps a missing resource from failing at the end of a meeting.

Usage:
  generate-prompts.py            write src/Minutes.Core/Prompts/SharedPrompts.g.cs
  generate-prompts.py --check    exit non-zero if the file is stale
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT.parent / "shared" / "prompts"
OUT = ROOT / "src" / "Minutes.Core" / "Prompts" / "SharedPrompts.g.cs"


def cs_string(text):
    """A single-line C# literal. Not a raw/verbatim string: those are sensitive
    to embedded quotes and indentation, which is exactly how a prompt could
    silently change."""
    escaped = (text.replace("\\", "\\\\")
                   .replace('"', '\\"')
                   .replace("\n", "\\n")
                   .replace("\t", "\\t")
                   .replace("\r", "\\r"))
    return '"' + escaped + '"'


def generate():
    summary = json.loads((SHARED / "summary.json").read_text(encoding="utf-8"))
    chat = json.loads((SHARED / "chat.json").read_text(encoding="utf-8"))
    detection = json.loads((SHARED / "detection-apps.json").read_text(encoding="utf-8"))
    recipes = json.loads((SHARED / "recipes.json").read_text(encoding="utf-8"))

    lines = [
        "// GENERATED FILE — DO NOT EDIT.",
        "//",
        "// Source of truth: shared/prompts/*.json",
        "// Regenerate:      windows/Scripts/generate-prompts.py",
        "//",
        "// The prompts are shared with the macOS app, so editing them here would",
        "// silently desynchronise the two. Edit the JSON instead.",
        "",
        "namespace Minutes.Core.Prompts;",
        "",
        "public static class SharedPrompts",
        "{",
        "    public static class Summary",
        "    {",
        "        public const string SystemPrompt = " + cs_string(summary["systemPrompt"]) + ";",
        "        public const string NotesGuidance = " + cs_string(summary["notesGuidance"]) + ";",
        "        public const string NotesNone = " + cs_string(summary["notesNone"]) + ";",
        "        public const string TranscriptGuidance = " + cs_string(summary["transcriptGuidance"]) + ";",
        "        public const string ClosingGuidance = " + cs_string(summary["closingGuidance"]) + ";",
        "        public const string LanguageInstruction = " + cs_string(summary["languageInstruction"]) + ";",
        "        public const string TitleInstruction = " + cs_string(summary["titleInstruction"]) + ";",
        "        public const string RecordedByLine = " + cs_string(summary["recordedByLine"]) + ";",
        "",
        "        public sealed record Template(string Id, string Name, string Blurb, string Instructions);",
        "",
        "        public static readonly Template[] Templates =",
        "        [",
    ]
    for t in summary["templates"]:
        lines.append("            new(" + cs_string(t["id"]) + ",")
        lines.append("                " + cs_string(t["name"]) + ",")
        lines.append("                " + cs_string(t["blurb"]) + ",")
        lines.append("                " + cs_string(t["instructions"]) + "),")
    lines += [
        "        ];",
        "    }",
        "",
        "    public static class Chat",
        "    {",
        "        public const string SystemPrompt = " + cs_string(chat["systemPrompt"]) + ";",
        "        public const string IndexNote = " + cs_string(chat["indexNote"]) + ";",
        "        public const string CoverageNote = " + cs_string(chat["coverageNote"]) + ";",
        "        public const string UserLine = " + cs_string(chat["userLine"]) + ";",
        "    }",
        "",
        "    public static class Detection",
        "    {",
        "        public sealed record App(string Prefix, string Name, bool Ambiguous);",
        "",
        "        public static readonly App[] Apps =",
        "        [",
    ]
    for a in detection["apps"]:
        lines.append("            new(" + cs_string(a["prefix"]) + ", " + cs_string(a["name"])
                     + ", " + ("true" if a["ambiguous"] else "false") + "),")
    lines += [
        "        ];",
        "    }",
        "",
        "    public static class Recipes",
        "    {",
        "        /// <param name=\"Scope\">\"meeting\", \"library\" or \"any\".</param>",
        "        public sealed record Recipe(string Id, string Title, string Scope, string Prompt);",
        "",
        "        public static readonly Recipe[] All =",
        "        [",
    ]
    for r in recipes["recipes"]:
        lines.append("            new(" + cs_string(r["id"]) + ", " + cs_string(r["title"]) + ",")
        lines.append("                " + cs_string(r["scope"]) + ",")
        lines.append("                " + cs_string(r["prompt"]) + "),")
    lines += ["        ];", "    }", "}", ""]
    return "\n".join(lines)


def main():
    generated = generate()
    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != generated:
            print("error: SharedPrompts.g.cs is stale — run windows/Scripts/generate-prompts.py",
                  file=sys.stderr)
            return 1
        print("    prompts up to date")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(generated, encoding="utf-8", newline="\n")
    print("wrote " + str(OUT.relative_to(ROOT)) + " (" + str(len(generated)) + " bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
