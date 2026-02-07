import Foundation

/// Configuration for supported Whisper models
struct ModelsConfig {
    struct ModelInfo: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let url: String  // HuggingFace tree URL
    }
    
    static let supportedModels: [ModelInfo] = [
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_547MB",
            name: "Whisper Large V3 547",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_547MB"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3_594MB",
            name: "Distil Whisper Large V3 594",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3_594MB"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo",
            name: "Whisper Large V3 T",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_turbo"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            name: "Whisper Large V3 632T",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_turbo_632MB"
        ),
        ModelInfo(
            id: "openai_whisper-large-v3",
            name: "Whisper Large V3",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3"
        ),
        ModelInfo(
            id: "distil-whisper_distil-large-v3",
            name: "Distil Whisper Large V3",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/distil-whisper_distil-large-v3"
        ),
        ModelInfo(
            id: "openai_whisper-base",
            name: "Whisper Base",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base"
        ),
        ModelInfo(
            id: "openai_whisper-small",
            name: "Whisper Small",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small"
        ),
        ModelInfo(
            id: "openai_whisper-tiny",
            name: "Whisper Tiny",
            url: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny"
        )
    ]
}
