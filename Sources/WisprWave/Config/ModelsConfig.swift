import Foundation

/// Catalog of supported models for every speech engine
struct ModelsConfig {
    struct ModelInfo: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let engine: SpeechEngine
        /// HuggingFace tree URL. Whisper only; Parakeet models are fetched by FluidAudio,
        /// which picks the version from the id (see ParakeetEngine).
        let url: String?

        init(id: String, name: String, engine: SpeechEngine = .whisper, url: String? = nil) {
            self.id = id
            self.name = name
            self.engine = engine
            self.url = url
        }
    }

    /// Looks up a catalog entry by id.
    static func model(id: String) -> ModelInfo? {
        supportedModels.first(where: { $0.id == id })
    }

    /// The catalog entries for one engine, in catalog order.
    static func models(for engine: SpeechEngine) -> [ModelInfo] {
        supportedModels.filter { $0.engine == engine }
    }

    static let supportedModels: [ModelInfo] = [
        // --- Whisper (WhisperKit) ---
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_547MB",
            name: "Whisper Large V3 547 New",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_547MB"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "Whisper Large V3 626 New",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_626MB"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930",
            name: "Whisper Large V3 New",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo",
            name: "Whisper Large V3 T New",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_turbo"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            name: "Whisper Large V3 632T New",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_turbo_632MB"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3_594MB",
            name: "Distil Whisper Large V3 594",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3_594MB"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3",
            name: "Distil Whisper Large V3",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3_turbo",
            name: "Distil Whisper Large V3 T",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3_turbo"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3_turbo_600MB",
            name: "Distil Whisper Large V3 600T",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3_turbo_600MB"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3",
            name: "Whisper Large V3",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-large-v3"
        ),
        ModelInfo(
            id: "openai_whisper-medium.en",
            name: "Whisper Medium En",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-medium.en"
        ),
        ModelInfo(
            id: "openai_whisper-medium",
            name: "Whisper Medium",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-medium"
        ),
        ModelInfo(
            id: "openai_whisper-small.en",
            name: "Whisper Small En",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-small.en"
        ),
        ModelInfo(
            id: "openai_whisper-small.en_217MB",
            name: "Whisper Small En 217",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-small.en_217MB"
        ),
        ModelInfo(
            id: "openai_whisper-small",
            name: "Whisper Small",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-small"
        ),
        ModelInfo(
            id: "openai_whisper-base.en",
            name: "Whisper Base En",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-base.en"
        ),
        ModelInfo(
            id: "openai_whisper-base",
            name: "Whisper Base",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-base"
        ),
        ModelInfo(
            id: "openai_whisper-tiny.en",
            name: "Whisper Tiny En",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-tiny.en"
        ),
        ModelInfo(
            id: "openai_whisper-tiny",
            name: "Whisper Tiny",
            url: "https://huggingface.co/plive/whisperkit-coreml/tree/main/openai_whisper-tiny"
        ),

        // --- Parakeet (FluidAudio) ---
        ModelInfo(
            id: "parakeet-tdt-0.6b-v2",
            name: "Parakeet v2 (English)",
            engine: .parakeet
        ),
        ModelInfo(
            id: "parakeet-tdt-0.6b-v3",
            name: "Parakeet v3 (25 languages)",
            engine: .parakeet
        )
    ]
}
