import ballerina/ai;
import ballerina/log;
import ballerina/lang.runtime;
import ballerinax/ai.anthropic;

ai:ModelProvider? anthropicModel = ();
configurable string apiKey = ?;

const int AI_MAX_RETRIES = 4;
const decimal AI_RETRY_INITIAL_DELAY = 10.0; // seconds; doubles on each attempt

public function initAIService(boolean quietMode = false) returns error? {
    ai:ModelProvider|error modelProvider = new anthropic:ModelProvider(
        apiKey,
        anthropic:CLAUDE_OPUS_4_5,
        maxTokens = 64000,
        timeout = 400
    );
    if modelProvider is error {
        return error("Failed to initialize model provider", modelProvider);
    }
    anthropicModel = modelProvider;

    if !quietMode {
        log:printInfo("LLM service initialized successfully");
    }
}

public function callAI(string prompt) returns string|error {
    ai:ModelProvider? model = anthropicModel;
    if model is () {
        return error("AI model not initialized. Please call initAIService() first.");
    }

    ai:ChatMessage[] messages = [{role: "user", content: prompt}];
    decimal delay = AI_RETRY_INITIAL_DELAY;
    error? lastErr = ();
    foreach int attempt in 1 ..< AI_MAX_RETRIES + 1 {
        ai:ChatAssistantMessage|error response = model->chat(messages);
        if response is ai:ChatAssistantMessage {
            string? content = response.content;
            if content is string {
                return content;
            }
            return error("AI response content is empty.");
        }
        lastErr = response;
        if attempt < AI_MAX_RETRIES {
            log:printWarn(string `AI call failed (attempt ${attempt}/${AI_MAX_RETRIES}): ${response.message()}. Retrying in ${delay}s...`);
            error? sleepErr = runtime:sleep(delay);
            if sleepErr is error {
                log:printWarn(string `Sleep interrupted: ${sleepErr.message()}`);
            }
            delay *= 2.0d;
        }
    }
    return error("AI generation failed: " + (lastErr is error ? lastErr.message() : "unknown error"));
}

// Multi-turn version: caller builds up the full conversation history and passes it.
// Returns the assistant reply content for the final turn.
public function callAIWithMessages(ai:ChatMessage[] messages) returns string|error {
    ai:ModelProvider? model = anthropicModel;
    if model is () {
        return error("AI model not initialized. Please call initAIService() first.");
    }

    decimal delay = AI_RETRY_INITIAL_DELAY;
    error? lastErr = ();
    foreach int attempt in 1 ..< AI_MAX_RETRIES + 1 {
        ai:ChatAssistantMessage|error response = model->chat(messages);
        if response is ai:ChatAssistantMessage {
            string? content = response.content;
            if content is string {
                return content;
            }
            return error("AI response content is empty.");
        }
        lastErr = response;
        if attempt < AI_MAX_RETRIES {
            log:printWarn(string `AI call failed (attempt ${attempt}/${AI_MAX_RETRIES}): ${response.message()}. Retrying in ${delay}s...`);
            error? sleepErr = runtime:sleep(delay);
            if sleepErr is error {
                log:printWarn(string `Sleep interrupted: ${sleepErr.message()}`);
            }
            delay *= 2.0d;
        }
    }
    return error("AI generation failed: " + (lastErr is error ? lastErr.message() : "unknown error"));
}

public function isAIServiceInitialized() returns boolean {
    return anthropicModel !is ();
}
