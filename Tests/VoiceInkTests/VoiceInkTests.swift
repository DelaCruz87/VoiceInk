//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func transcriptPasteFormatterAddsOnlyTranscriptLabel() {
        #expect(
            TranscriptPasteFormatter.format("Texto dictado.")
                == "Transcript\n\nTexto dictado."
        )
    }

    @Test func transcriptPasteFormatterPreservesTranscriptVerbatim() {
        #expect(
            TranscriptPasteFormatter.format("  Texto con espacios\nsegunda línea  ")
                == "Transcript\n\n  Texto con espacios\nsegunda línea  "
        )
    }

}
