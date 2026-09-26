import re

file_path = "Plume/PlaybackRoutingCoordinator.swift"

with open(file_path, "r") as f:
    content = f.read()

# 1. Insert Constants enum
constants_enum = """    private enum Constants {
        static let voiceUnavailable = "The selected Apple voice is unavailable."
        static func playbackActivationFailed(_ desc: String) -> String { "Unable to activate audio playback: \\(desc)" }
        static func fallbackActivationFailed(_ desc: String) -> String { "Unable to activate audio session for fallback: \\(desc)" }
        static let speechCancelled = "Apple speech was cancelled."
        static let defaultLanguageCode = "en"
        static let defaultVoiceLanguage = "en-US"
        static let underscore = "_"
        static let dash = "-"
    }

    // MARK: - State Machine & Producer Ownership"""

content = content.replace("    // MARK: - State Machine & Producer Ownership", constants_enum)

# 2. Replace usages
content = content.replace('"The selected Apple voice is unavailable."', "Constants.voiceUnavailable")
content = content.replace('"Unable to activate audio playback: \\(error.localizedDescription)"', "Constants.playbackActivationFailed(error.localizedDescription)")
content = content.replace('"Unable to activate audio session for fallback: \\(error.localizedDescription)"', "Constants.fallbackActivationFailed(error.localizedDescription)")
content = content.replace('"Apple speech was cancelled."', "Constants.speechCancelled")
content = content.replace('"en"', "Constants.defaultLanguageCode")
content = content.replace('"en-US"', "Constants.defaultVoiceLanguage")
content = content.replace('"_"', "Constants.underscore")
content = content.replace('"-"', "Constants.dash")

# 3. Remove Log.audio statements
lines = content.split('\n')
new_lines = []
for line in lines:
    if "Log.audio.info" in line or "Log.audio.warning" in line or "Log.audio.error" in line:
        continue
    new_lines.append(line)

with open(file_path, "w") as f:
    f.write('\n'.join(new_lines))

print("Fixed magic strings and removed debug statements")
