import connector_automator.utils;

import ballerina/file;
import ballerina/io;
import ballerina/log;

# Reads sanitations.md and re-applies every code-level rule to the generated
# client.bal and types.bal so the version analyser sees a clean diff.
#
# + projectDir  - Ballerina project directory containing client.bal / types.bal
# + sanitationsPath - Absolute path to sanitations.md
# + quietMode   - Suppress verbose output when true
# + return      - error if any step fails, () on success
public function applyCodeSanitations(string projectDir, string sanitationsPath, boolean quietMode = false) returns error? {
    if !utils:isAIServiceInitialized() {
        if !quietMode {
            io:println("⚠  AI service not available — skipping code sanitation step");
        }
        return;
    }

    // Read sanitations.md
    boolean|file:Error sanitationsExists = file:test(sanitationsPath, file:EXISTS);
    if sanitationsExists is file:Error || !sanitationsExists {
        if !quietMode {
            io:println("⚠  sanitations.md not found — skipping code sanitation step");
        }
        return;
    }

    string|io:Error sanitationsContent = io:fileReadString(sanitationsPath);
    if sanitationsContent is io:Error {
        return error("Failed to read sanitations.md: " + sanitationsContent.message());
    }

    if (<string>sanitationsContent).trim().length() == 0 {
        if !quietMode {
            io:println("ℹ  sanitations.md is empty — skipping code sanitation step");
        }
        return;
    }

    string sanitations = <string>sanitationsContent;

    // Apply to client.bal and types.bal
    string[] targets = ["client.bal", "types.bal"];
    foreach string fileName in targets {
        string filePath = projectDir + "/" + fileName;
        boolean|file:Error fileExists = file:test(filePath, file:EXISTS);
        if fileExists is file:Error || !fileExists {
            if !quietMode {
                log:printWarn("File not found, skipping sanitation", fileName = fileName);
            }
            continue;
        }

        string|io:Error fileContent = io:fileReadString(filePath);
        if fileContent is io:Error {
            log:printError("Failed to read file", fileName = fileName, 'error = fileContent);
            continue;
        }

        if !quietMode {
            io:println(string `  Applying code sanitations to ${fileName}...`);
        }

        string|error corrected = applySanitationsToFile(<string>fileContent, fileName, sanitations);
        if corrected is error {
            log:printError("LLM failed to apply sanitations", fileName = fileName, 'error = corrected);
            io:println(string `  ⚠  Could not apply sanitations to ${fileName}: ${corrected.message()}`);
            continue;
        }

        io:Error? writeErr = io:fileWriteString(filePath, <string>corrected, io:OVERWRITE);
        if writeErr is io:Error {
            return error(string `Failed to write corrected ${fileName}: ${writeErr.message()}`);
        }

        if !quietMode {
            io:println(string `  ✓ Sanitations applied to ${fileName}`);
        }
    }
}

# Calls the LLM to apply sanitation rules from sanitations.md to a single file.
function applySanitationsToFile(string fileContent, string fileName, string sanitationsContent) returns string|error {
    string prompt = buildSanitationPrompt(fileContent, fileName, sanitationsContent);
    string|error response = utils:callAI(prompt);
    if response is error {
        return error("AI call failed: " + response.message());
    }
    return stripMarkdownFences(<string>response);
}

function buildSanitationPrompt(string fileContent, string fileName, string sanitationsContent) returns string {
    string balOpenapiCmd = "`bal openapi`";
    return string `You are an expert Ballerina developer maintaining a Ballerina connector.

A connector was regenerated from an updated OpenAPI spec using ${balOpenapiCmd}.
The regenerated code must have the same manual sanitation rules applied that were applied to the previous version.
These rules are recorded in sanitations.md.

SANITATIONS.MD (the rules that MUST be applied):
${sanitationsContent}

FILE TO CORRECT (${fileName}):
${fileContent}

TASK:
Read every rule in sanitations.md carefully.
Apply ONLY the rules that affect Ballerina source code (field types, nullability, type renames, path-prefix removal reflected in query/parameter type names, etc.).
Do NOT apply rules that only affect the OpenAPI spec or documentation text.

IMPORTANT RULES:
- Return ONLY the complete, corrected Ballerina source code for ${fileName}.
- Do NOT wrap the output in markdown code fences or add any explanation.
- If a rule does not apply to this file, leave the file unchanged for that rule.
- Preserve all existing imports, annotations, and code structure.
- Apply type changes exactly as specified (e.g. string to int for IDs stated as integers).
- Apply nullability exactly as specified (e.g. add ? to fields stated as nullable).
- Remove path prefixes from generated type/query-record names exactly as specified.

Now return the complete corrected ${fileName}:`;
}

# Strip leading/trailing markdown code fences that the LLM may add.
function stripMarkdownFences(string raw) returns string {
    string trimmed = raw.trim();
    // Remove opening fence (```ballerina or ```)
    if trimmed.startsWith("```") {
        int? newline = trimmed.indexOf("\n");
        if newline is int {
            trimmed = trimmed.substring(newline + 1);
        }
    }
    // Remove closing fence
    if trimmed.endsWith("```") {
        trimmed = trimmed.substring(0, trimmed.length() - 3).trim();
    }
    return trimmed;
}
