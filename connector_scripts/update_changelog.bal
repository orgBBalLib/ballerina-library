import ballerina/file;
import ballerina/io;
import ballerina/regex;

type ChangelogEntry record {|
    string changeType;
    string[] items;
|};

function parsePrDescription(string prDescription) returns map<string[]>|error {
    map<string[]> changes = {
        "Added": [],
        "Changed": [],
        "Fixed": []
    };

    string[] lines = regex:split(prDescription, "\n");
    string currentSection = "";

    foreach string line in lines {
        string trimmed = line.trim();

        if trimmed == "Breaking Changes" || trimmed == "### Breaking Changes" {
            currentSection = "Changed";
        } else if trimmed == "New Features" || trimmed == "### New Features" {
            currentSection = "Added";
        } else if trimmed == "Improvements" || trimmed == "### Improvements" {
            currentSection = "Fixed";
        } else if trimmed.startsWith("*") || trimmed.startsWith("-") {
            string item = regex:replaceAll(trimmed, "^[*\\-]\\s*", "");
            item = item.trim();

            if item.length() > 0 && currentSection.length() > 0 {
                string[] existing = changes[currentSection] ?: [];
                existing.push(item);
                changes[currentSection] = existing;
            }
        }
    }

    return changes;
}

function generateUnreleasedSection(map<string[]> changes) returns string {
    string[] lines = ["## [Unreleased]", ""];

    string[] added = changes["Added"] ?: [];
    if added.length() > 0 {
        lines.push("### Added");
        foreach string item in added {
            lines.push(string `- ${item}`);
        }
        lines.push("");
    }

    string[] changed = changes["Changed"] ?: [];
    if changed.length() > 0 {
        lines.push("### Changed");
        foreach string item in changed {
            lines.push(string `- ${item}`);
        }
        lines.push("");
    }

    string[] fixed = changes["Fixed"] ?: [];
    if fixed.length() > 0 {
        lines.push("### Fixed");
        foreach string item in fixed {
            lines.push(string `- ${item}`);
        }
        lines.push("");
    }

    return string:'join("\n", ...lines);
}

function findChangelogFile() returns string|error? {
    string[] possibleNames = ["CHANGELOG.md", "changelog.md", "Changelog.md", "ChangeLog.md"];

    foreach string name in possibleNames {
        if check file:test(name, file:EXISTS) {
            return name;
        }
    }

    return ();
}

function updateChangelog(string prDescription) returns error? {
    io:println("Updating CHANGELOG.md...");

    map<string[]> changes = check parsePrDescription(prDescription);

    int totalChanges = (changes["Added"] ?: []).length() +
                       (changes["Changed"] ?: []).length() +
                       (changes["Fixed"] ?: []).length();

    if totalChanges == 0 {
        io:println("No changelog entries found in PR description");
        return;
    }

    string? existingFile = check findChangelogFile();
    string changelogPath = existingFile is string ? existingFile : "CHANGELOG.md";

    io:println(string `Using changelog file: ${changelogPath}`);

    string newUnreleasedSection = generateUnreleasedSection(changes);

    if existingFile is string {
        string content = check io:fileReadString(changelogPath);
        string[] lines = regex:split(content, "\n");

        int unreleasedIndex = -1;
        foreach int i in 0 ..< lines.length() {
            if lines[i].trim().startsWith("## [Unreleased]") {
                unreleasedIndex = i;
                break;
            }
        }

        if unreleasedIndex >= 0 {
            int nextSectionIndex = lines.length();
            foreach int i in (unreleasedIndex + 1) ..< lines.length() {
                if lines[i].trim().startsWith("## [") {
                    nextSectionIndex = i;
                    break;
                }
            }

            string[] updatedLines = [];

            foreach int i in 0 ..< unreleasedIndex {
                updatedLines.push(lines[i]);
            }

            string[] newSectionLines = regex:split(newUnreleasedSection, "\n");
            foreach string line in newSectionLines {
                updatedLines.push(line);
            }

            foreach int i in nextSectionIndex ..< lines.length() {
                updatedLines.push(lines[i]);
            }

            string updatedContent = string:'join("\n", ...updatedLines);
            check io:fileWriteString(changelogPath, updatedContent);
            io:println("Updated existing CHANGELOG.md");
        } else {
            int insertIndex = 0;

            foreach int i in 0 ..< lines.length() {
                if lines[i].trim().startsWith("#") && !lines[i].trim().startsWith("##") {
                    insertIndex = i + 1;
                    break;
                }
            }

            string[] updatedLines = [];

            foreach int i in 0 ..< insertIndex {
                updatedLines.push(lines[i]);
            }

            if insertIndex < lines.length() && lines[insertIndex].trim().length() > 0 {
                updatedLines.push("");
            }

            string[] newSectionLines = regex:split(newUnreleasedSection, "\n");
            foreach string line in newSectionLines {
                updatedLines.push(line);
            }

            foreach int i in insertIndex ..< lines.length() {
                updatedLines.push(lines[i]);
            }

            string updatedContent = string:'join("\n", ...updatedLines);
            check io:fileWriteString(changelogPath, updatedContent);
            io:println("Added [Unreleased] section to existing CHANGELOG.md");
        }
    } else {
        string changelogTemplate = string `# Change Log

This file contains all the notable changes done to the Ballerina connector through the releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

${newUnreleasedSection}`;

        check io:fileWriteString(changelogPath, changelogTemplate);
        io:println("Created new CHANGELOG.md");
    }

    io:println(string `Added ${totalChanges} changelog entries`);
}

public function main(string prDescription) returns error? {
    check updateChangelog(prDescription);
}
