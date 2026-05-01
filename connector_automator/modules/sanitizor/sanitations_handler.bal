import connector_automator.utils;

import ballerina/file;
import ballerina/io;
import ballerina/regex;

// ─────────────────────────────────────────────────────────────
// INTERNAL TYPES (private to this file)
// ─────────────────────────────────────────────────────────────

type ServerUrlChange record {|
    string original;
    string updated;
    string reason;
|};

type PathPrefixRule record {|
    string prefixRemoved;
    string reason;
|};

type TypeChange record {|
    string schemaName;
    string fieldName;
    string originalType;
    string updatedType;
    string reason;
|};

type NullabilityChange record {|
    string schemaName;
    string fieldName;
    boolean nullable;
    string reason;
|};

type FormatChange record {|
    string originalFormat;
    string updatedFormat;
    string reason;
|};

type SanitationRules record {|
    ServerUrlChange[] serverUrlChanges = [];
    PathPrefixRule[] pathPrefixRules = [];
    TypeChange[] typeChanges = [];
    NullabilityChange[] nullabilityChanges = [];
    FormatChange[] formatChanges = [];
    string[] rawEntries = [];
|};

// ─────────────────────────────────────────────────────────────
// PUBLIC API — called from main.bal
// ─────────────────────────────────────────────────────────────

# Generate sanitations.md after a fresh connector generation.
# Call this after sanitizor:executeSanitizor completes in the standard pipeline.
#
# + originalSpecPath - path to the raw input OpenAPI spec
# + alignedSpecPath  - path to the aligned_ballerina_openapi.json produced by sanitizor
# + outputDir        - connector root directory (sanitations.md goes to outputDir/docs/spec/)
# + quietMode        - suppress verbose output
# + return           - error if writing fails
public function generateSanitationsDoc(
        string originalSpecPath,
        string alignedSpecPath,
        string outputDir,
        boolean quietMode = false) returns error? {

    if !quietMode {
        io:println("Generating sanitations.md documentation...");
    }

    string sanitationsPath = outputDir + "/docs/spec/sanitations.md";

    // Read both specs; if original is YAML the JSON read will fail gracefully
    json originalSpec = {};
    json alignedSpec = {};

    json|error originalResult = io:fileReadJson(originalSpecPath);
    if originalResult is json {
        originalSpec = originalResult;
    }

    json|error alignedResult = io:fileReadJson(alignedSpecPath);
    if alignedResult is json {
        alignedSpec = alignedResult;
    }

    string content = check buildSanitationsContent(
            originalSpec, alignedSpec, originalSpecPath, quietMode);

    check io:fileWriteString(sanitationsPath, content);

    if !quietMode {
        io:println(string `✓ Generated sanitations.md at: ${sanitationsPath}`);
    }
}

# Read sanitations.md and apply recorded changes to the new spec before sanitization.
# Call this before sanitizor:executeSanitizor in the regeneration pipeline.
#
# + sanitationsPath - path to the existing sanitations.md
# + newSpecPath     - path to the newly downloaded OpenAPI spec (will be modified in-place)
# + quietMode       - suppress verbose output
# + return          - error if reading/writing fails
public function applySanitations(
        string sanitationsPath,
        string newSpecPath,
        boolean quietMode = false) returns error? {

    boolean exists = check file:test(sanitationsPath, file:EXISTS);
    if !exists {
        if !quietMode {
            io:println("⚠  No sanitations.md found — skipping pre-sanitization step");
        }
        return;
    }

    if !quietMode {
        io:println(string `Reading sanitations from: ${sanitationsPath}`);
    }

    string content = check io:fileReadString(sanitationsPath);

    // Try LLM-based parsing first — handles multi-field entries, typos, Ballerina-specific skips
    SanitationRules rules;
    SanitationRules|error llmRules = parseSanitationsWithLLM(content, quietMode);
    if llmRules is SanitationRules {
        rules = llmRules;
        if !quietMode {
            io:println("  (parsed using AI)");
        }
    } else {
        if !quietMode {
            io:println(string `  ⚠  AI parsing unavailable (${llmRules.message()}), using programmatic parser`);
        }
        rules = parseSanitationsMarkdown(content);
    }

    if !quietMode {
        io:println(string `  Server URL rules   : ${rules.serverUrlChanges.length()}`);
        io:println(string `  Path prefix rules  : ${rules.pathPrefixRules.length()}`);
        io:println(string `  Type change rules  : ${rules.typeChanges.length()}`);
        io:println(string `  Nullability rules  : ${rules.nullabilityChanges.length()}`);
        io:println(string `  Format rules       : ${rules.formatChanges.length()}`);
    }

    check applyRulesToSpec(newSpecPath, rules, quietMode);

    if !quietMode {
        io:println("✓ Sanitations applied to new spec");
    }
}

// ─────────────────────────────────────────────────────────────
// MARKDOWN GENERATION
// ─────────────────────────────────────────────────────────────

function buildSanitationsContent(
        json originalSpec,
        json alignedSpec,
        string originalSpecPath,
        boolean quietMode) returns string|error {

    string[] lines = [];
    string bt = "`"; // backtick helper to avoid string template issues

    lines.push("# Sanitation for OpenAPI specification");
    lines.push("");
    lines.push("This document records the sanitation done on top of the official OpenAPI specification.");
    lines.push("");

    int changeIndex = 1;

    // --- Server URL ---
    string originalServer = extractServerUrl(originalSpec);
    string alignedServer = extractServerUrl(alignedSpec);

    if originalServer != "" && alignedServer != "" && originalServer != alignedServer {
        lines.push(string `${changeIndex}. Change the ${bt}url${bt} property of the servers object`);
        lines.push(string `- **Original**: ${bt}${originalServer}${bt}`);
        lines.push(string `- **Updated**: ${bt}${alignedServer}${bt}`);
        lines.push("- **Reason**: Common prefix added to base URL to simplify endpoint paths.");
        lines.push("");
        changeIndex += 1;
    }

    // --- Removed path prefix ---
    string removedPrefix = detectRemovedPathPrefix(originalSpec, alignedSpec);
    if removedPrefix != "" {
        lines.push(string `${changeIndex}. Update the API Paths`);
        lines.push(string `- **Original**: Paths included common prefix ${bt}${removedPrefix}${bt} in each endpoint.`);
        lines.push("- **Updated**: Common prefix removed from endpoints as it is now in the base URL.");
        lines.push("- **Reason**: Simplifies API paths and avoids duplication.");
        lines.push("");
        changeIndex += 1;
    }

    // --- Format changes ---
    FormatChange[] formatChanges = detectFormatChanges(originalSpec, alignedSpec);
    foreach FormatChange fc in formatChanges {
        lines.push(string `${changeIndex}. Update ${bt}${fc.originalFormat}${bt} to ${bt}${fc.updatedFormat}${bt}`);
        lines.push(string `- **Original**: ${bt}"format":"${fc.originalFormat}"${bt}`);
        lines.push(string `- **Updated**: ${bt}"format":"${fc.updatedFormat}"${bt}`);
        lines.push(string `- **Reason**: ${fc.reason}`);
        lines.push("");
        changeIndex += 1;
    }

    // --- Nullability changes ---
    NullabilityChange[] nullChanges = detectNullabilityChanges(originalSpec, alignedSpec);
    foreach NullabilityChange nc in nullChanges {
        string nowStr = nc.nullable ? "nullable" : "not nullable";
        string wasStr = nc.nullable ? "not nullable" : "nullable";
        lines.push(string `${changeIndex}. Change ${bt}${nc.schemaName} ${nc.fieldName}${bt} to ${nowStr}`);
        lines.push(string `- **Original**: The ${bt}${nc.fieldName}${bt} field in ${bt}${nc.schemaName}${bt} was ${bt}${wasStr}${bt}.`);
        lines.push(string `- **Updated**: The ${bt}${nc.fieldName}${bt} field has been updated to be ${bt}${nowStr}${bt}.`);
        lines.push(string `- **Reason**: ${nc.reason}`);
        lines.push("");
        changeIndex += 1;
    }

    // --- Type changes ---
    TypeChange[] typeChanges = detectTypeChanges(originalSpec, alignedSpec);
    foreach TypeChange tc in typeChanges {
        lines.push(string `${changeIndex}. Change ${bt}${tc.fieldName}${bt} from ${bt}${tc.originalType}${bt} to ${bt}${tc.updatedType}${bt}`);
        lines.push(string `- **Original**: The ${bt}${tc.fieldName}${bt} field was defined as a ${bt}${tc.originalType}${bt}.`);
        lines.push(string `- **Updated**: The ${bt}${tc.fieldName}${bt} field has been changed to ${bt}${tc.updatedType}${bt}.`);
        lines.push(string `- **Reason**: ${tc.reason}`);
        lines.push("");
        changeIndex += 1;
    }

    // --- Footer ---
    lines.push("## OpenAPI cli command");
    lines.push("");
    lines.push("The following command was used to generate the Ballerina client from the OpenAPI specification.");
    lines.push("The command should be executed from the repository root directory.");
    lines.push("");
    lines.push("```bash");
    lines.push("bal openapi -i docs/spec/openapi.json -o ballerina --mode client --license docs/license.txt");
    lines.push("```");
    lines.push("");
    lines.push("Note: The license year is hardcoded to 2025, change if necessary.");

    return string:'join("\n", ...lines);
}

// ─────────────────────────────────────────────────────────────
// LLM-BASED MARKDOWN PARSING
// ─────────────────────────────────────────────────────────────

function parseSanitationsWithLLM(string content, boolean quietMode) returns SanitationRules|error {
    if !utils:isAIServiceInitialized() {
        return error("LLM service not initialized");
    }

    string prompt = string `You are analyzing a Ballerina connector sanitations.md document.
Extract ALL sanitation rules that apply to an OpenAPI JSON spec as structured JSON.

SANITATIONS.MD CONTENT:
${content}

RULES TO EXTRACT:
1. serverUrlChanges: Changes to the server URL (original → updated)
2. pathPrefixRules: Path prefix removals (just the prefix string, e.g. "/crm/v4")
3. formatChanges: OpenAPI format value changes (extract only the value, e.g. "date-time" not '"format":"date-time"')
4. nullabilityChanges: Fields made nullable in schemas (schemaName, fieldName, nullable true/false)
5. typeChanges: Field type changes in schemas (schemaName, fieldName, originalType, updatedType)

IMPORTANT RULES:
- For typeChanges where one section mentions MULTIPLE fields, produce one separate entry per field
- For typeChanges without a specific schema mentioned, use empty string "" for schemaName
- SKIP sections about Ballerina-level code changes (e.g. int:signed32, record fields in generated code)
- SKIP sections about summary/description/documentation enhancements (those are handled by AI separately)
- Only include changes that modify the raw OpenAPI spec JSON structure
- Return ONLY valid JSON with no markdown fences

REQUIRED RESPONSE FORMAT:
{
  "serverUrlChanges": [{"original": "...", "updated": "...", "reason": "..."}],
  "pathPrefixRules": [{"prefixRemoved": "...", "reason": "..."}],
  "formatChanges": [{"originalFormat": "...", "updatedFormat": "...", "reason": "..."}],
  "nullabilityChanges": [{"schemaName": "...", "fieldName": "...", "nullable": true, "reason": "..."}],
  "typeChanges": [{"schemaName": "...", "fieldName": "...", "originalType": "...", "updatedType": "...", "reason": "..."}]
}`;

    string|error response = utils:callAI(prompt);
    if response is error {
        return error("LLM call failed: " + response.message());
    }

    // Strip markdown fences if the model added them anyway
    string cleaned = response.trim();
    if cleaned.startsWith("```") {
        int? firstNewline = cleaned.indexOf("\n");
        if firstNewline is int {
            cleaned = cleaned.substring(firstNewline + 1);
        }
        if cleaned.endsWith("```") {
            cleaned = cleaned.substring(0, cleaned.length() - 3).trim();
        }
    }

    json|error jsonResult = cleaned.fromJsonString();
    if jsonResult is error {
        return error("Failed to parse LLM response as JSON: " + jsonResult.message());
    }

    return jsonToSanitationRules(jsonResult);
}

function jsonToSanitationRules(json data) returns SanitationRules|error {
    if !(data is map<json>) {
        return error("LLM response is not a JSON object");
    }
    map<json> root = <map<json>>data;
    SanitationRules rules = {};

    // serverUrlChanges
    json|error suArr = root.get("serverUrlChanges");
    if suArr is json[] {
        foreach json item in suArr {
            if item is map<json> {
                json|error orig = item.get("original");
                json|error upd = item.get("updated");
                json|error rsn = item.get("reason");
                if orig is string && upd is string {
                    rules.serverUrlChanges.push({
                        original: orig,
                        updated: upd,
                        reason: rsn is string ? rsn : ""
                    });
                }
            }
        }
    }

    // pathPrefixRules
    json|error ppArr = root.get("pathPrefixRules");
    if ppArr is json[] {
        foreach json item in ppArr {
            if item is map<json> {
                json|error pfx = item.get("prefixRemoved");
                json|error rsn = item.get("reason");
                if pfx is string {
                    rules.pathPrefixRules.push({
                        prefixRemoved: pfx,
                        reason: rsn is string ? rsn : ""
                    });
                }
            }
        }
    }

    // formatChanges
    json|error fcArr = root.get("formatChanges");
    if fcArr is json[] {
        foreach json item in fcArr {
            if item is map<json> {
                json|error orig = item.get("originalFormat");
                json|error upd = item.get("updatedFormat");
                json|error rsn = item.get("reason");
                if orig is string && upd is string {
                    rules.formatChanges.push({
                        originalFormat: orig,
                        updatedFormat: upd,
                        reason: rsn is string ? rsn : ""
                    });
                }
            }
        }
    }

    // nullabilityChanges
    json|error ncArr = root.get("nullabilityChanges");
    if ncArr is json[] {
        foreach json item in ncArr {
            if item is map<json> {
                json|error sn = item.get("schemaName");
                json|error fn = item.get("fieldName");
                json|error nl = item.get("nullable");
                json|error rsn = item.get("reason");
                if sn is string && fn is string && nl is boolean {
                    rules.nullabilityChanges.push({
                        schemaName: sn,
                        fieldName: fn,
                        nullable: nl,
                        reason: rsn is string ? rsn : ""
                    });
                }
            }
        }
    }

    // typeChanges
    json|error tcArr = root.get("typeChanges");
    if tcArr is json[] {
        foreach json item in tcArr {
            if item is map<json> {
                json|error sn = item.get("schemaName");
                json|error fn = item.get("fieldName");
                json|error ot = item.get("originalType");
                json|error ut = item.get("updatedType");
                json|error rsn = item.get("reason");
                if fn is string && ot is string && ut is string {
                    rules.typeChanges.push({
                        schemaName: sn is string ? sn : "",
                        fieldName: fn,
                        originalType: ot,
                        updatedType: ut,
                        reason: rsn is string ? rsn : ""
                    });
                }
            }
        }
    }

    return rules;
}

// ─────────────────────────────────────────────────────────────
// MARKDOWN PARSING
// ─────────────────────────────────────────────────────────────

function parseSanitationsMarkdown(string content) returns SanitationRules {
    SanitationRules rules = {};
    string[] lines = regex:split(content, "\n");

    int i = 0;
    while i < lines.length() {
        string line = lines[i].trim();

        // Match numbered list items like "1. ..." or "12. ..."
        if regex:matches(line, "[0-9]+\\..*") {
            string sectionTitle = line.toLowerAscii();

            // Collect the whole block until the next numbered item
            string[] blockLines = [line];
            int j = i + 1;
            while j < lines.length() {
                string nextLine = lines[j].trim();
                if regex:matches(nextLine, "[0-9]+\\..*") {
                    break;
                }
                blockLines.push(nextLine);
                j += 1;
            }
            string block = string:'join("\n", ...blockLines);

            if sectionTitle.includes("url") && sectionTitle.includes("server") {
                ServerUrlChange? sc = parseServerUrlBlock(blockLines);
                if sc is ServerUrlChange {
                    rules.serverUrlChanges.push(sc);
                }
            } else if sectionTitle.includes("path") &&
                    (sectionTitle.includes("prefix") || sectionTitle.includes("endpoint") || sectionTitle.includes("api path")) {
                PathPrefixRule? pr = parsePathPrefixBlock(blockLines);
                if pr is PathPrefixRule {
                    rules.pathPrefixRules.push(pr);
                }
            } else if sectionTitle.includes("format") || sectionTitle.includes("date-time") || sectionTitle.includes("datetime") {
                FormatChange? fc = parseFormatBlock(blockLines);
                if fc is FormatChange {
                    rules.formatChanges.push(fc);
                }
            } else if sectionTitle.includes("nullable") || sectionTitle.includes("null") {
                NullabilityChange? nc = parseNullabilityBlock(blockLines);
                if nc is NullabilityChange {
                    rules.nullabilityChanges.push(nc);
                }
            } else if sectionTitle.includes("type") || sectionTitle.includes("integer") ||
                    sectionTitle.includes("string") || sectionTitle.includes("change") {
                TypeChange? tc = parseTypeChangeBlock(blockLines);
                if tc is TypeChange {
                    rules.typeChanges.push(tc);
                }
            } else {
                rules.rawEntries.push(block);
            }

            i = j;
            continue;
        }

        i += 1;
    }

    return rules;
}

function parseServerUrlBlock(string[] lines) returns ServerUrlChange? {
    string original = "";
    string updated = "";
    string reason = "";

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("- **Original**") {
            original = extractFirstBacktickValue(t);
        } else if t.startsWith("- **Updated**") {
            updated = extractFirstBacktickValue(t);
        } else if t.startsWith("- **Reason**") {
            int? colon = t.indexOf(":");
            if colon is int {
                reason = t.substring(colon + 1).trim();
            }
        }
    }

    if original != "" && updated != "" {
        return {original, updated, reason};
    }
    return ();
}

function parsePathPrefixBlock(string[] lines) returns PathPrefixRule? {
    string prefixRemoved = "";
    string reason = "";

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("- **Original**") {
            string val = extractFirstBacktickValue(t);
            if val != "" {
                prefixRemoved = val;
            }
        } else if t.startsWith("- **Reason**") {
            int? colon = t.indexOf(":");
            if colon is int {
                reason = t.substring(colon + 1).trim();
            }
        }
    }

    if prefixRemoved != "" {
        return {prefixRemoved, reason};
    }
    return ();
}

function parseFormatBlock(string[] lines) returns FormatChange? {
    string originalFormat = "";
    string updatedFormat = "";
    string reason = "";

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("- **Original**") {
            originalFormat = cleanFormatValue(extractFirstBacktickValue(t));
        } else if t.startsWith("- **Updated**") {
            updatedFormat = cleanFormatValue(extractFirstBacktickValue(t));
        } else if t.startsWith("- **Reason**") {
            int? colon = t.indexOf(":");
            if colon is int {
                reason = t.substring(colon + 1).trim();
            }
        }
    }

    if originalFormat != "" && updatedFormat != "" {
        return {originalFormat, updatedFormat, reason};
    }
    return ();
}

function parseNullabilityBlock(string[] lines) returns NullabilityChange? {
    string schemaName = "";
    string fieldName = "";
    boolean nullable = true;
    string reason = "";

    // Parse schema/field from section title line
    if lines.length() > 0 {
        string titleLine = lines[0];
        string titleLower = titleLine.toLowerAscii();
        string[] backtickVals = extractAllBacktickValues(titleLine);
        if backtickVals.length() >= 1 {
            string[] nameParts = regex:split(backtickVals[0], " ");
            if nameParts.length() >= 2 {
                schemaName = nameParts[0];
                fieldName = nameParts[1];
            } else if nameParts.length() == 1 {
                fieldName = nameParts[0];
            }
        }
        nullable = !titleLower.includes("not nullable");
    }

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("- **Reason**") {
            int? colon = t.indexOf(":");
            if colon is int {
                reason = t.substring(colon + 1).trim();
            }
        }
    }

    if fieldName != "" {
        return {schemaName, fieldName, nullable, reason};
    }
    return ();
}

function parseTypeChangeBlock(string[] lines) returns TypeChange? {
    string schemaName = "";
    string fieldName = "";
    string originalType = "";
    string updatedType = "";
    string reason = "";

    // Parse field from section title
    if lines.length() > 0 {
        string[] backtickVals = extractAllBacktickValues(lines[0]);
        if backtickVals.length() >= 1 {
            string[] nameParts = regex:split(backtickVals[0], " ");
            if nameParts.length() >= 2 {
                schemaName = nameParts[0];
                fieldName = nameParts[1];
            } else if nameParts.length() == 1 {
                fieldName = nameParts[0];
            }
        }
    }

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("- **Original**") {
            // Hand-written format: "The `fieldName` field was defined as a `type`." → 2nd backtick
            // Generated format: same pattern — always take the last backtick value as the type
            string[] vals = extractAllBacktickValues(t);
            originalType = vals.length() >= 2 ? vals[vals.length() - 1] : (vals.length() >= 1 ? vals[0] : "");
        } else if t.startsWith("- **Updated**") {
            string[] vals = extractAllBacktickValues(t);
            updatedType = vals.length() >= 2 ? vals[vals.length() - 1] : (vals.length() >= 1 ? vals[0] : "");
        } else if t.startsWith("- **Reason**") {
            int? colon = t.indexOf(":");
            if colon is int {
                reason = t.substring(colon + 1).trim();
            }
        }
    }

    if fieldName != "" && originalType != "" && updatedType != "" {
        return {schemaName, fieldName, originalType, updatedType, reason};
    }
    return ();
}

// ─────────────────────────────────────────────────────────────
// APPLY RULES TO SPEC
// ─────────────────────────────────────────────────────────────

function applyRulesToSpec(string specPath, SanitationRules rules, boolean quietMode) returns error? {
    json|error specResult = io:fileReadJson(specPath);
    if specResult is error {
        return error("Failed to read spec at " + specPath + ": " + specResult.message());
    }

    json specJson = specResult;
    if !(specJson is map<json>) {
        return error("Spec is not a JSON object");
    }

    map<json> spec = <map<json>>specJson;

    foreach ServerUrlChange sc in rules.serverUrlChanges {
        applyServerUrlChange(spec, sc, quietMode);
    }

    foreach PathPrefixRule pr in rules.pathPrefixRules {
        applyPathPrefixRemoval(spec, pr, quietMode);
    }

    foreach FormatChange fc in rules.formatChanges {
        applyFormatChange(spec, fc, quietMode);
    }

    foreach NullabilityChange nc in rules.nullabilityChanges {
        applyNullabilityChange(spec, nc, quietMode);
    }

    foreach TypeChange tc in rules.typeChanges {
        applyTypeChange(spec, tc, quietMode);
    }

    // Write back using toJsonString — no extra import needed
    string updatedContent = spec.toJsonString();
    check io:fileWriteString(specPath, updatedContent);
}

function applyServerUrlChange(map<json> spec, ServerUrlChange sc, boolean quietMode) {
    json|error serversResult = spec.get("servers");
    if serversResult is json[] {
        json[] servers = <json[]>serversResult;
        foreach json server in servers {
            if server is map<json> {
                map<json> serverMap = <map<json>>server;
                json|error urlResult = serverMap.get("url");
                if urlResult is string && <string>urlResult == sc.original {
                    serverMap["url"] = sc.updated;
                    if !quietMode {
                        io:println(string `  ✓ Server URL: ${sc.original} → ${sc.updated}`);
                    }
                }
            }
        }
    }
}

function applyPathPrefixRemoval(map<json> spec, PathPrefixRule pr, boolean quietMode) {
    json|error pathsResult = spec.get("paths");
    if pathsResult is map<json> {
        map<json> paths = <map<json>>pathsResult;
        map<json> newPaths = {};
        int modified = 0;

        foreach string path in paths.keys() {
            json|error pathValue = paths.get(path);
            if pathValue is json {
                if path.startsWith(pr.prefixRemoved) {
                    string newPath = path.substring(pr.prefixRemoved.length());
                    if newPath == "" || newPath == "/" {
                        newPath = "/";
                    }
                    newPaths[newPath] = pathValue;
                    modified += 1;
                } else {
                    newPaths[path] = pathValue;
                }
            }
        }

        spec["paths"] = newPaths;
        if !quietMode && modified > 0 {
            io:println(string `  ✓ Removed path prefix '${pr.prefixRemoved}' from ${modified} paths`);
        }
    }
}

function applyFormatChange(map<json> spec, FormatChange fc, boolean quietMode) {
    int count = countFormatOccurrences(spec, fc.originalFormat);
    replaceFormatValues(spec, fc.originalFormat, fc.updatedFormat);
    if !quietMode && count > 0 {
        io:println(string `  ✓ Format '${fc.originalFormat}' → '${fc.updatedFormat}' (${count} occurrences)`);
    }
}

function replaceFormatValues(json data, string originalFormat, string updatedFormat) {
    if data is map<json> {
        map<json> dataMap = <map<json>>data;
        foreach string key in dataMap.keys() {
            json|error val = dataMap.get(key);
            if val is json {
                if key == "format" && val is string && <string>val == originalFormat {
                    dataMap[key] = updatedFormat;
                } else {
                    replaceFormatValues(val, originalFormat, updatedFormat);
                }
            }
        }
    } else if data is json[] {
        json[] arr = <json[]>data;
        foreach json item in arr {
            replaceFormatValues(item, originalFormat, updatedFormat);
        }
    }
}

function countFormatOccurrences(json data, string formatValue) returns int {
    int count = 0;
    if data is map<json> {
        map<json> dataMap = <map<json>>data;
        foreach string key in dataMap.keys() {
            json|error val = dataMap.get(key);
            if val is json {
                if key == "format" && val is string && <string>val == formatValue {
                    count += 1;
                } else {
                    count += countFormatOccurrences(val, formatValue);
                }
            }
        }
    } else if data is json[] {
        json[] arr = <json[]>data;
        foreach json item in arr {
            count += countFormatOccurrences(item, formatValue);
        }
    }
    return count;
}

function applyNullabilityChange(map<json> spec, NullabilityChange nc, boolean quietMode) {
    map<json> schemas = extractSchemas(spec);
    string[] targets = nc.schemaName != "" ? [nc.schemaName] : schemas.keys();

    foreach string schemaName in targets {
        json|error schemaResult = schemas.get(schemaName);
        if schemaResult is map<json> {
            boolean changed = applyNullabilityToSchema(<map<json>>schemaResult, nc.fieldName, nc.nullable);
            if changed && !quietMode {
                io:println(string `  ✓ ${schemaName}.${nc.fieldName} → nullable=${nc.nullable}`);
            }
        }
    }
}

// NEW - safe
function applyNullabilityToSchema(map<json> schemaMap, string fieldName, boolean nullable) returns boolean {
    json|error propertiesResult = schemaMap.get("properties");
    if propertiesResult is map<json> {
        map<json> properties = <map<json>>propertiesResult;
        if !properties.hasKey(fieldName) {
            return false;
        }
        json|error fieldResult = properties.get(fieldName);
        if fieldResult is map<json> {
            map<json> fieldMap = <map<json>>fieldResult;
            fieldMap["nullable"] = nullable;
            return true;
        }
    }
    return false;
}
function applyTypeChange(map<json> spec, TypeChange tc, boolean quietMode) {
    map<json> schemas = extractSchemas(spec);
    string[] targets = tc.schemaName != "" ? [tc.schemaName] : schemas.keys();

    foreach string schemaName in targets {
        json|error schemaResult = schemas.get(schemaName);
        if schemaResult is map<json> {
            boolean changed = applyTypeChangeToSchema(<map<json>>schemaResult, tc.fieldName, tc.originalType, tc.updatedType);
            if changed && !quietMode {
                io:println(string `  ✓ ${schemaName}.${tc.fieldName}: ${tc.originalType} → ${tc.updatedType}`);
            }
        }
    }
}

// NEW - safe, uses hasKey before get
function applyTypeChangeToSchema(map<json> schemaMap, string fieldName, string originalType, string updatedType) returns boolean {
    json|error propertiesResult = schemaMap.get("properties");
    if propertiesResult is map<json> {
        map<json> properties = <map<json>>propertiesResult;
        if !properties.hasKey(fieldName) {
            return false;
        }
        json|error fieldResult = properties.get(fieldName);
        if fieldResult is map<json> {
            map<json> fieldMap = <map<json>>fieldResult;
            if !fieldMap.hasKey("type") {
                return false;
            }
            json|error currentType = fieldMap.get("type");
            if currentType is string && <string>currentType == originalType {
                fieldMap["type"] = updatedType;
                return true;
            }
        }
    }
    return false;
}
// ─────────────────────────────────────────────────────────────
// DIFF HELPERS — used during sanitations.md generation
// ─────────────────────────────────────────────────────────────

function extractServerUrl(json spec) returns string {
    if spec is map<json> {
        json|error serversResult = spec.get("servers");
        if serversResult is json[] {
            json[] servers = <json[]>serversResult;
            if servers.length() > 0 {
                json firstServer = servers[0];
                if firstServer is map<json> {
                    json|error urlResult = firstServer.get("url");
                    if urlResult is string {
                        return <string>urlResult;
                    }
                }
            }
        }
    }
    return "";
}

function detectRemovedPathPrefix(json originalSpec, json alignedSpec) returns string {
    string[] originalPaths = extractPathKeys(originalSpec);
    string[] alignedPaths = extractPathKeys(alignedSpec);

    if originalPaths.length() == 0 || alignedPaths.length() == 0 {
        return "";
    }

    string firstOriginal = originalPaths[0];
    string firstAligned = alignedPaths[0];

    // The prefix is what was prepended; aligned path is suffix of original path
    if firstOriginal.length() > firstAligned.length() {
        int suffixStart = firstOriginal.length() - firstAligned.length();
        string suffix = firstOriginal.substring(suffixStart);
        if suffix == firstAligned {
            return firstOriginal.substring(0, suffixStart);
        }
    }

    return "";
}

function extractPathKeys(json spec) returns string[] {
    string[] keys = [];
    if spec is map<json> {
        json|error pathsResult = spec.get("paths");
        if pathsResult is map<json> {
            map<json> paths = <map<json>>pathsResult;
            foreach string key in paths.keys() {
                keys.push(key);
            }
        }
    }
    return keys;
}

function detectFormatChanges(json originalSpec, json alignedSpec) returns FormatChange[] {
    FormatChange[] changes = [];

    boolean origHasDatetime = specContainsFormat(originalSpec, "date-time");
    boolean alignedHasNewFormat = specContainsFormat(alignedSpec, "datetime");

    if origHasDatetime && alignedHasNewFormat {
        changes.push({
            originalFormat: "date-time",
            updatedFormat: "datetime",
            reason: "The `date-time` format is not compatible with the openAPI generation tool. Updated to `datetime` for Ballerina compatibility."
        });
    }

    return changes;
}

function specContainsFormat(json spec, string formatValue) returns boolean {
    if spec is map<json> {
        map<json> specMap = <map<json>>spec;
        foreach string key in specMap.keys() {
            json|error val = specMap.get(key);
            if val is json {
                if key == "format" && val is string && <string>val == formatValue {
                    return true;
                }
                if specContainsFormat(val, formatValue) {
                    return true;
                }
            }
        }
    } else if spec is json[] {
        json[] arr = <json[]>spec;
        foreach json item in arr {
            if specContainsFormat(item, formatValue) {
                return true;
            }
        }
    }
    return false;
}

function detectNullabilityChanges(json originalSpec, json alignedSpec) returns NullabilityChange[] {
    NullabilityChange[] changes = [];

    map<json> originalSchemas = extractSchemas(originalSpec);
    map<json> alignedSchemas = extractSchemas(alignedSpec);

    foreach string schemaName in alignedSchemas.keys() {
        json|error alignedSchemaResult = alignedSchemas.get(schemaName);
        json|error originalSchemaResult = originalSchemas.get(schemaName);

        if alignedSchemaResult is map<json> {
            map<json> alignedSchema = <map<json>>alignedSchemaResult;
            map<json> originalSchema = originalSchemaResult is map<json> ? <map<json>>originalSchemaResult : {};

            json|error aPropsResult = alignedSchema.get("properties");
            json|error oPropsResult = originalSchema.get("properties");

            if aPropsResult is map<json> {
                map<json> aProps = <map<json>>aPropsResult;
                map<json> oProps = oPropsResult is map<json> ? <map<json>>oPropsResult : {};

                foreach string fieldName in aProps.keys() {
                    json|error aFieldResult = aProps.get(fieldName);
                    json|error oFieldResult = oProps.get(fieldName);

                    if aFieldResult is map<json> {
                        map<json> aField = <map<json>>aFieldResult;
                        boolean isNullableInAligned = aField.hasKey("nullable") &&
                                aField.get("nullable") == true;

                        boolean isNullableInOriginal = false;
                        if oFieldResult is map<json> {
                            map<json> oField = <map<json>>oFieldResult;
                            isNullableInOriginal = oField.hasKey("nullable") &&
                                    oField.get("nullable") == true;
                        }

                        if isNullableInAligned && !isNullableInOriginal {
                            changes.push({
                                schemaName,
                                fieldName,
                                nullable: true,
                                reason: "The API can return a null value for this field."
                            });
                        }
                    }
                }
            }
        }
    }

    return changes;
}

function detectTypeChanges(json originalSpec, json alignedSpec) returns TypeChange[] {
    TypeChange[] changes = [];

    map<json> originalSchemas = extractSchemas(originalSpec);
    map<json> alignedSchemas = extractSchemas(alignedSpec);

    foreach string schemaName in alignedSchemas.keys() {
        json|error alignedSchemaResult = alignedSchemas.get(schemaName);
        json|error originalSchemaResult = originalSchemas.get(schemaName);

        if alignedSchemaResult is map<json> && originalSchemaResult is map<json> {
            map<json> alignedSchema = <map<json>>alignedSchemaResult;
            map<json> originalSchema = <map<json>>originalSchemaResult;

            json|error aPropsResult = alignedSchema.get("properties");
            json|error oPropsResult = originalSchema.get("properties");

            if aPropsResult is map<json> && oPropsResult is map<json> {
                map<json> aProps = <map<json>>aPropsResult;
                map<json> oProps = <map<json>>oPropsResult;

                foreach string fieldName in aProps.keys() {
                    json|error aFieldResult = aProps.get(fieldName);
                    json|error oFieldResult = oProps.get(fieldName);

                    if aFieldResult is map<json> && oFieldResult is map<json> {
                        map<json> aField = <map<json>>aFieldResult;
                        map<json> oField = <map<json>>oFieldResult;

                        json|error aTypeResult = aField.get("type");
                        json|error oTypeResult = oField.get("type");

                        if aTypeResult is string && oTypeResult is string {
                            string aType = <string>aTypeResult;
                            string oType = <string>oTypeResult;
                            if aType != oType {
                                changes.push({
                                    schemaName,
                                    fieldName,
                                    originalType: oType,
                                    updatedType: aType,
                                    reason: string `The API returns ${fieldName} as ${aType}; updated for accurate representation.`
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    return changes;
}

function extractSchemas(json spec) returns map<json> {
    if spec is map<json> {
        json|error componentsResult = spec.get("components");
        if componentsResult is map<json> {
            map<json> components = <map<json>>componentsResult;
            json|error schemasResult = components.get("schemas");
            if schemasResult is map<json> {
                return <map<json>>schemasResult;
            }
        }
    }
    return {};
}

// ─────────────────────────────────────────────────────────────
// STRING UTILITIES
// ─────────────────────────────────────────────────────────────

function extractFirstBacktickValue(string line) returns string {
    int? startPos = line.indexOf("`");
    if startPos is int {
        int searchFrom = startPos + 1;
        if searchFrom < line.length() {
            int? end = line.indexOf("`", searchFrom);
            if end is int && end > startPos {
                return line.substring(startPos + 1, end);
            }
        }
    }
    return "";
}

function extractAllBacktickValues(string line) returns string[] {
    string[] values = [];
    int pos = 0;
    while pos < line.length() {
        int? startPos = line.indexOf("`", pos);
        if startPos is () {
            break;
        }
        int startVal = startPos;
        int searchFrom = startVal + 1;
        if searchFrom >= line.length() {
            break;
        }
        int? end = line.indexOf("`", searchFrom);
        if end is () {
            break;
        }
        int endVal = end;
        values.push(line.substring(startVal + 1, endVal));
        pos = endVal + 1;
    }
    return values;
}

function cleanFormatValue(string raw) returns string {
    string trimmed = raw.trim();
    // Handle `"format":"value"` or `"foramt":"value"` (handles typos in hand-written docs)
    int? colonQuotePos = trimmed.indexOf(":\"");
    if colonQuotePos is int {
        string afterColon = trimmed.substring(colonQuotePos + 2);
        int? endQuote = afterColon.indexOf("\"");
        if endQuote is int {
            return afterColon.substring(0, endQuote).trim();
        }
        return afterColon.trim();
    }
    // Plain value (no key wrapper) — just strip any stray quotes
    return regex:replaceAll(trimmed, "\"", "").trim();
}
