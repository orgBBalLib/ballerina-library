import connector_automator.utils;

import ballerina/io;
import ballerina/time;

public function generateAndWriteSanitationsDoc(
    string sanitizedSpecPath,
    string sanitationsOutputPath,
    string existingSanitations,
    int operationIdsAdded,
    int schemasRenamed,
    int descriptionsAdded,
    boolean quietMode
) returns error? {
    if !utils:isAIServiceInitialized() {
        if !quietMode {
            io:println("⚠  AI service not available - skipping sanitations.md generation");
        }
        return;
    }

    string currentDate = getCurrentDateString();
    string apiInfo = extractApiInfoFromSpec(sanitizedSpecPath);
    string serverUrl = extractServerUrlFromSpec(sanitizedSpecPath);

    string openApiCliBlock = "```bash\nbal openapi -i docs/spec/openapi.yaml -o ballerina --mode client --license docs/license.txt\n```";

    string prompt;
    if existingSanitations.length() > 0 {
        prompt = string `You are updating an existing API sanitation documentation file.

API: ${apiInfo}
Server URL: ${serverUrl}

AUTOMATED CHANGES IN THIS REGENERATION RUN:
- OperationIds generated: ${operationIdsAdded}
- Schema names generated: ${schemasRenamed}
- Field/parameter descriptions added: ${descriptionsAdded}

EXISTING SANITATIONS.MD:
${existingSanitations}

TASK: Return the COMPLETE updated sanitations.md.
- Change ONLY the _Updated_ date to ${currentDate}
- Keep ALL existing entries exactly as they are — do not remove or reword any entry
- Return ONLY the raw markdown, no preamble or explanation`;
    } else {
        prompt = string `You are creating the initial sanitation documentation for a new Ballerina connector.

API: ${apiInfo}
Server URL after sanitization: ${serverUrl}

AUTOMATED SANITIZATION PERFORMED:
- ${operationIdsAdded} missing operationIds generated
- ${schemasRenamed} generic schema names renamed to meaningful PascalCase names
- ${descriptionsAdded} missing field/parameter descriptions added

Generate a sanitations.md following this EXACT format (use \\ for line-break after each metadata field):

_Author_: @ballerina-bot \\
_Created_: ${currentDate} \\
_Updated_: ${currentDate} \\
_Edition_: Swan Lake

# Sanitation for OpenAPI specification

This document records the sanitation done on top of the official OpenAPI specification from [API Name] Connector.
The OpenAPI specification is obtained from [source URL — omit line if unknown].
These changes are done in order to improve the overall usability, and as workarounds for some known language limitations.

1. [Document any server URL or base-path change that is evident from the server URL above]
- **Original**: [original value]
- **Updated**: [new value]
- **Reason**: [short explanation]

2. AI-Enhanced Metadata Generation
- **Added**: Generated ${operationIdsAdded} missing operationIds, renamed ${schemasRenamed} generic schema names to meaningful PascalCase names, and added ${descriptionsAdded} field/parameter descriptions.
- **Reason**: Improves client readability and usability.

## OpenAPI cli command

The following command was used to generate the Ballerina client from the OpenAPI specification. The command should be executed from the repository root directory.

${openApiCliBlock}
Note: The license year is hardcoded to the current year, change if necessary.

Return ONLY the raw markdown content — no preamble, no explanation.`;
    }

    string|error response = utils:callAI(prompt);
    if response is error {
        return error("Failed to generate sanitations document: " + response.message());
    }

    error? writeResult = io:fileWriteString(sanitationsOutputPath, response);
    if writeResult is error {
        return error("Failed to write sanitations.md: " + writeResult.message());
    }
}

function getCurrentDateString() returns string {
    time:Utc now = time:utcNow();
    time:Civil civil = time:utcToCivil(now);
    string year = civil.year.toString();
    int monthInt = civil.month;
    int dayInt = civil.day;
    string month = monthInt < 10 ? "0" + monthInt.toString() : monthInt.toString();
    string day = dayInt < 10 ? "0" + dayInt.toString() : dayInt.toString();
    return string `${year}/${month}/${day}`;
}

function extractApiInfoFromSpec(string specPath) returns string {
    json|error specResult = io:fileReadJson(specPath);
    if specResult is error {
        return "API information not available";
    }
    return extractApiContext(specResult);
}

function extractServerUrlFromSpec(string specPath) returns string {
    json|error specResult = io:fileReadJson(specPath);
    if specResult is error {
        return "";
    }
    json spec = specResult;
    if spec is map<json> {
        json|error serversResult = (<map<json>>spec).get("servers");
        if serversResult is json[] {
            json[] servers = <json[]>serversResult;
            if servers.length() > 0 {
                json firstServer = servers[0];
                if firstServer is map<json> {
                    json|error urlResult = (<map<json>>firstServer).get("url");
                    if urlResult is string {
                        return <string>urlResult;
                    }
                }
            }
        }
    }
    return "";
}
