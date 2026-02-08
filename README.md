# 🌊 WisprWave

**The Intelligent, Private, Fast Speech-to-Text for macOS.**

**WisprWave** brings OpenAI's powerful **Whisper** models directly to your Mac menu bar. Experience class-leading transcription speed and accuracy without sending a single byte of data to the cloud. It's completely free, works offline, and injects text into *any* application.

---

## 🚀 Key Features

*   **⚡️ Blazing Fast:** Powered by `WhisperKit` and optimized for Apple Silicon (CoreML). Transcription happens locally and instantly.
*   **🔒 100% Private:** Your voice never leaves your device. Works completely offline—airplane mode approved.
*   **🤖 State-of-the-Art Accuracy:** Supports the latest Whisper Large-v3 models (and smaller variants) for nuanced, accurate transcription.
*   **⌨️ Universal Dictation:** Injects text directly into your active application (Notes, Slack, Obsidian, VS Code, etc.).
*   **💻 VM Compatible:** Special legacy mode designed for virtual machines (VMware, Parallels, UTM).

---

## 🎛️ Performance Modes

WisprWave adapts to your environment with two distinct modes:

### 🚀 Boost Mode (Default)
**Maximum Speed.**
For native macOS environments, Boost Mode employs intelligent background streaming to transcribe your speech in real-time as you talk.
*   **Instant Results:** Text is ready almost the moment you stop speaking.
*   **How it Works:** Processes audio in small chunks continuously.
*   **⚠️ Note:** To achieve this speed, the engine relies on chunk processing. If you stop recording *immediately* (<0.5 seconds) after your last word, the final snippet might occasionally be missed. For critical accuracy, pause briefly before stopping.

### 🐢 Legacy Mode (VM Support)
**Maximum Compatibility.**
Some virtualized environments or older systems restrict direct hardware audio access required for streaming.
*   **Dependable:** Records to a temporary file first, then transcribes the full buffer.
*   **Robust:** Slower than Boost Mode, but ensures compatibility where other dictation apps fail.
*   **Ideal For:** Use this if you are running macOS inside a VM or experience audio driver issues.

---

## � Download

Don't want to build from source? Download the latest ready-to-use app:

👉 [**Download WisprWave.zip**](https://github.com/panks/WisprWave/releases/latest)

1.  Download the zip file.
2.  Unzip and drag `WisprWave.app` to your Applications folder.
3.  Follow the launch instructions below.

---

## �🛠️ Installation from Source

WisprWave is open-source. Build it directly from the codebase in minutes.

### Prerequisites
*   macOS 14.0+ (Sonoma or later recommended)
*   Xcode 15+ (for Swift 6 support)

### Steps

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/yourusername/WisprWave.git
    cd WisprWave
    ```

2.  **Build and Package:**
    We've included a helper script to build and sign the app bundle automatically.
    ```bash
    ./package_app.sh
    ```

3.  **Launch:**
    Open the generated app in the project directory:
    ```bash
    open WisprWave.app
    ```

    > **⚠️ Note:** Since this app is not signed with an Apple Developer ID, macOS (Gatekeeper) may block it.
    > *   **System Settings:** Go to *System Settings > Privacy & Security* and click "Open Anyway" near the bottom.
    > *   **Alternative:** Right-click the app in Finder, select *Open*, and confirm in the dialog.

4.  **Permissions:**
    On first launch, grant **Accessibility** (for text injection) and **Microphone** permissions when prompted. The menu bar icon will appear, ready for action!

---

## 🤝 Contributing

Contributions are welcome! Feel free to open issues or submit pull requests to make WisprWave even better.

## 📄 License

MIT License. Free for everyone.
