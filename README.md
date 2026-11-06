# Native Granola

A macOS menu bar app that takes meeting notes the way [Granola](https://granola.ai) does: no bot joins the call. It listens to your microphone and to whatever your Mac plays, transcribes both on-device, and turns the transcript and your own notes into structured notes with Grok when the call ends. A built-in MCP server lets Cursor and other AI tools search and read your meetings.

It is a personal project, written in Swift with no third-party dependencies, and not affiliated with Granola.

## How it works

Your Mac already hears both sides of a call: your voice comes in through the microphone, and everyone else comes out of the speakers. The app records these as two separate streams, so it knows who said what without guessing. The microphone is "Me"; system audio is "Them".

- **System audio** comes from a Core Audio process tap (macOS 14.2+), the same API Granola uses. There's no virtual audio driver to install.
- **Microphone audio** runs through Apple's voice processing, which cancels echo when you take calls on speakers. A text-level filter drops anything the canceller misses.
- **Transcription** uses Apple's on-device `SpeechAnalyzer` (macOS 26). It is free, private and streams words as they're spoken. Audio is never written to disk.
- **Notes** come from Grok, through the xAI API, once the call ends. It works from the transcript, your typed notes and the calendar event. Templates shape the output for 1:1s, sales calls, standups, interviews and more.
- **Meeting detection** watches your calendar and shows a prompt a minute before events with two or more attendees. It also notices when Zoom, Teams, Slack, FaceTime or a browser starts using the microphone, and offers to take notes. When that app releases the mic, the app stops recording and writes the notes.
- **Storage** is a local SQLite database with full-text search, at `~/Library/Application Support/NativeGranola/granola.sqlite`.

## Requirements

- macOS 26 or later, on Apple Silicon
- Swift 6.2 or later. The Command Line Tools are enough; Xcode is not required.
- An [xAI API key](https://console.x.ai) for AI notes. Recording and transcription work without one.

## Build and run

```sh
scripts/setup-signing.sh      # once: creates a local code-signing identity
scripts/bundle.sh release     # builds and signs build/NativeGranola.app
open build/NativeGranola.app
```

The signing step matters. macOS ties microphone and system-audio permissions to the app's signature, and a self-signed certificate keeps that signature stable, so you grant permissions once instead of after every build. The script stores the certificate in its own keychain under `signing/`, which is git-ignored.

`scripts/install.sh` does a release build, copies the app to `~/Applications`, registers the MCP server with Cursor and launches it.

On first use, macOS asks for microphone, system audio recording and calendar access.

## Configure

Open Settings from the menu bar icon.

- **AI:** paste your xAI key, which the app keeps in the macOS Keychain. The default model is `grok-4.20-0309-non-reasoning`, which writes a meeting's notes in about five seconds. `grok-4.7` gives similar notes in closer to a minute.
- **Notion:** create an internal integration at [notion.so/profile/integrations](https://www.notion.so/profile/integrations), add it to a page under ••• → Connections, then paste the token and the page's URL. The app creates a "Meeting Notes" database there and exports each note as a row, with the transcript in a toggle.
- **Cursor MCP:** click "Add to Cursor".

## Use it from Cursor

The app's binary doubles as a stdio MCP server. "Add to Cursor" writes this to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "native-granola": {
      "command": "/path/to/NativeGranola.app/Contents/MacOS/NativeGranola",
      "args": ["--mcp"]
    }
  }
}
```

It exposes five read-only tools: `list_meetings`, `get_meeting`, `get_transcript`, `search_meetings` and `get_current_meeting`. The last one reads the meeting in progress, so you can ask about a call while it's still happening. Everything stays on your Mac; the server reads the same database the app writes.

## Development

```sh
scripts/test.sh                              # all tests
scripts/test.sh --filter GranolaCoreTests    # one module
```

The app also has headless self-tests that run through the signed bundle, so macOS attributes permissions correctly:

```sh
open -W -n build/NativeGranola.app --args --selftest transcribe-file speech.aiff out.json
open -W -n build/NativeGranola.app --args --selftest record 15 out.json --no-mic
open -W -n build/NativeGranola.app --args --selftest enhance out.json
```

`record` captures live audio; pair it with `say` and `afplay` to test system-audio capture end to end.

The code lives in five modules:

| Module | Contents |
| --- | --- |
| `GranolaCore` | Models, SQLite store, full-text search, echo filter |
| `GranolaAudio` | Process tap, microphone capture, live transcription, the recorder |
| `GranolaDetection` | Calendar, mic activity, the detection rules, the prompt window |
| `GranolaIntelligence` | xAI client, note templates and generation, Notion export, Keychain |
| `GranolaMCP` | The MCP server |

`Sources/NativeGranola` holds the SwiftUI app that ties them together.

## Limitations

- System audio means everything your Mac plays. Music or a video in another tab lands in the transcript.
- Everyone on the far side of a call is "Them"; the app doesn't tell remote speakers apart.
- Transcription languages are whatever Apple's on-device model supports for your locale.
- Echo cancellation, the call-detection prompts and Notion export pass their tests but have had little real-world use.
